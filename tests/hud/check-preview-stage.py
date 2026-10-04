#!/usr/bin/env python3
"""Regression: a failed build must never replace the previous preview with stale output.
Runs a copy with isolated paths and failing build stubs; never runs the actual stage script.
"""
from pathlib import Path
import shlex
import subprocess
import tempfile

source = (Path.home() / '.wgsense-preview/stage.sh').read_text()
with tempfile.TemporaryDirectory(prefix='wgsense-stage-check-') as tmp:
    root = Path(tmp)
    repo, preview = root / 'repo', root / 'preview'
    (repo / 'platforms/macos').mkdir(parents=True)
    (preview / '.derived/Build/Products/Debug/WgSense.app').mkdir(parents=True)
    existing = preview / 'WgSense.app'
    existing.mkdir()
    sentinel = existing / 'keep-this-build'
    sentinel.write_text('previous valid preview')
    for name, body in [('generate', 'exit 0'), ('build', 'echo "intentional build failure"; exit 65')]:
        stub = root / name
        stub.write_text('#!/bin/bash\n' + body + '\n')
        stub.chmod(0o755)
    modified = source.replace('REPO="$HOME/Projects/wgsense"', 'REPO=' + shlex.quote(str(repo)))
    modified = modified.replace('DIR="$HOME/.wgsense-preview"', 'DIR=' + shlex.quote(str(preview)))
    modified = modified.replace('xcodegen generate', shlex.quote(str(root / 'generate')))
    modified = modified.replace('xcodebuild -project', shlex.quote(str(root / 'build')) + ' -project')
    # Fail closed if the real paths or build tools were not successfully replaced.
    assert '$HOME/Projects/wgsense' not in modified and '$HOME/.wgsense-preview' not in modified
    assert 'xcodebuild -project' not in modified and 'xcodegen generate' not in modified
    script = root / 'stage.sh'
    script.write_text(modified)
    result = subprocess.run(['/bin/bash', str(script)], capture_output=True, text=True)
    assert result.returncode != 0, result.stdout
    assert sentinel.read_text() == 'previous valid preview'
    assert not (preview / 'BUILD_INFO').exists()
    assert not (preview / 'WgSense.app.new').exists()
    print('PASS: failed build preserves previous preview and does not publish BUILD_INFO')

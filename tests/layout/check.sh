#!/bin/bash
# Builds and verifies the isolated fixture. Does not launch WgSense or access networking.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?Usage: check.sh /absolute/output/directory}"
bash "$HERE/build.sh" "$OUT"
BIN="$OUT/WgLayoutLab.app/Contents/MacOS/WgLayoutLab"
"$BIN" --verify "$OUT/verification.json"
"$BIN" --render "$OUT/renders"
python3 - "$OUT" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
results = []
for reference in sorted((root/'renders').glob('reference-*.png')):
    retained = reference.with_name(reference.name.replace('reference-', 'retained-'))
    same = reference.read_bytes() == retained.read_bytes()
    results.append(dict(width=reference.stem.replace('reference-', ''), identicalPNG=same,
                        sha256=hashlib.sha256(reference.read_bytes()).hexdigest()))
    if not same:
        raise SystemExit(f'Render mismatch: {reference.name}')
(root/'render-comparison.json').write_text(json.dumps(results, indent=2))
print(f'{len(results)} native render pairs are byte-identical')
PY

#!/usr/bin/env python3
"""Check the complete public-media inventory without third-party Python modules."""
import json
import hashlib
import struct
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent
repo = root.parent.parent
arguments = sys.argv[1:]
assert arguments in ([], ["--static"], ["--record-sources"]), "Usage: check-media.py [--static | --record-sources]"
static = arguments == ["--static"]
record = arguments == ["--record-sources"]
sources = [
    "platforms/macos/WgSense/Views/WgHUDMotion.swift",
    "platforms/macos/WgSense/Views/WgHUDDisplayClock.swift",
    "platforms/macos/WgSense/Views/WgLinkMonitor.swift",
    "platforms/macos/WgSense/Views/WgLinkStage.swift",
    "platforms/macos/WgSense/Views/WgDesign.swift",
    "platforms/macos/WgSense/Views/WgBrandIcon.swift",
    "tests/hud/render.swift",
    "tests/hud/render.sh",
    "docs/images/render-brand.swift",
    "docs/images/build-media.sh",
]
sources += sorted(str(p.relative_to(repo)) for p in
                  (repo / "platforms/macos/WgSense/Assets.xcassets/BrandIcon.imageset").iterdir()
                  if p.is_file())
source_hashes = {name: hashlib.sha256((repo / name).read_bytes()).hexdigest() for name in sources}
manifest = root / "source-hashes.json"
media_manifest = root / "media-hashes.json"
if not record:
    assert json.loads(manifest.read_text()) == source_hashes, "Public media source changed; regenerate with build-media.sh"
expected = {
    "hud-dark.png": (1552, 680),
    "hud-light.png": (1552, 680),
    "brand-appearance.png": (1440, 640),
}
for name, dimensions in expected.items():
    data = (root / name).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", name
    assert struct.unpack(">II", data[16:24]) == dimensions, name

gif = (root / "hud-motion.gif").read_bytes()
assert gif[:6] in (b"GIF87a", b"GIF89a")
assert struct.unpack("<HH", gif[6:10]) == (960, 470)
assert len(gif) < 5_000_000, "GIF must stay below 5 MB"

# The generated MP4 has one video track and no rotation. Inspect its native box
# structure and fixed-point dimensions even when ffprobe is unavailable in CI.
def boxes(data):
    position = 0
    while position < len(data):
        assert len(data) - position >= 8, "Truncated MP4 box"
        size, kind = struct.unpack(">I4s", data[position:position + 8])
        header = 8
        if size == 1:
            assert len(data) - position >= 16, "Truncated MP4 extended box"
            size = struct.unpack(">Q", data[position + 8:position + 16])[0]
            header = 16
        elif size == 0:
            size = len(data) - position
        assert header <= size <= len(data) - position, "Invalid MP4 box size"
        yield kind, data[position + header:position + size]
        position += size

movie = dict(boxes((root / "hud-motion.mp4").read_bytes()))
assert b"ftyp" in movie and b"mdat" in movie and b"moov" in movie, "Incomplete MP4"
video_dimensions = []
for kind, track in boxes(movie[b"moov"]):
    if kind != b"trak":
        continue
    children = dict(boxes(track))
    media = dict(boxes(children[b"mdia"]))
    if media[b"hdlr"][8:12] == b"vide":
        width, height = struct.unpack(">II", children[b"tkhd"][-8:])
        video_dimensions.append((width / 65536, height / 65536))
assert video_dimensions == [(1552, 760)], "Unexpected MP4 dimensions or video tracks"

actual = {p.name for p in root.iterdir() if p.suffix.lower() in {".png", ".gif", ".mp4"}}
assert actual == {*expected, "hud-motion.gif", "hud-motion.mp4"}, actual
media_hashes = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sorted(actual)}
if not record:
    assert json.loads(media_manifest.read_text()) == media_hashes, "Public media content changed; regenerate and fully validate with build-media.sh"

if not static:
    for name, fps, dimensions in [
        ("hud-motion.gif", "20/1", (960, 470)),
        ("hud-motion.mp4", "120/1", (1552, 760)),
    ]:
        result = subprocess.run([
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,avg_frame_rate:format=duration",
            "-of", "json", str(root / name),
        ], text=True, capture_output=True, check=True)
        details = json.loads(result.stdout)
        stream = details["streams"][0]
        assert (stream["width"], stream["height"]) == dimensions, name
        assert stream["avg_frame_rate"] == fps, name
        assert abs(float(details["format"]["duration"]) - 10.0) < 0.05, name

# Recording is permitted only after the complete checks, including ffprobe,
# succeed. Static checks compare against that fully validated byte inventory.
if record:
    manifest.write_text(json.dumps(source_hashes, indent=2, sort_keys=True) + "\n")
    media_manifest.write_text(json.dumps(media_hashes, indent=2, sort_keys=True) + "\n")
scope = "source freshness, structure, dimensions, content hashes and GIF size" if static else "source freshness, structure, dimensions, content hashes, duration, frame rates and GIF size"
print(f"PASS: 5/5 public media files; {scope} verified")

#!/usr/bin/env python3
"""Check the self-heal gutter in eight existing native HUD render fixtures.

Only compares the reserved gutter: legitimate pointer parallax outside it must
remain different. This is a focused pixel regression, not whole-page visual QA.
Usage: python3 tests/hud/check-gutter.py RENDER_DIRECTORY [--report report.json]
"""
import argparse
import json
from pathlib import Path

from PIL import Image, ImageChops


def contrast(pixel, background):
    return max(abs(channel - base) for channel, base in zip(pixel, background))


def point_box(box, scale):
    return tuple(round(value * scale) for value in box)


def pixel_data(image):
    # Keep compatibility with older Pillow without warnings on Pillow 12+.
    method = getattr(image, "get_flattened_data", None)
    return method() if method else image.getdata()


def inspect_marks(image, scale):
    background = image.getpixel((round(10 * scale), round(10 * scale)))
    # Both named fixtures have a full-opacity colored alarm title here. Its
    # contrast supplies a color-profile-independent reference. Empty .28-alpha
    # ticks must not pass as the twelve expected .9-alpha filled records.
    title = image.crop(point_box((185, 15, 353, 34), scale))
    reference = max(contrast(pixel, background) for pixel in pixel_data(title))
    marks = []
    for index in range(12):
        x = 373 - 95 + (index % 6) * 10 + 2
        y = 84 + (index // 6) * 18 + 5
        patch = image.crop(point_box((x - 0.75, y - 0.75, x + 0.75, y + 0.75), scale))
        measured = max(contrast(pixel, background) for pixel in pixel_data(patch))
        ratio = measured / reference if reference else 0
        marks.append({"index": index + 1, "contrast": measured,
                      "relative_contrast": round(ratio, 4),
                      "visible": reference >= 64 and ratio >= 0.75})
    return reference, marks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("render_directory", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    pairs, failures = [], []
    for mode in ("stall-max-rebind", "unstable-max-rebind"):
        for theme in ("dark", "light"):
            stem = f"{mode}-{theme}-373"
            entry = {"pair": stem, "files": []}
            images = []
            for motion in ("settled", "reduced"):
                filename = f"{stem}-{motion}.png"
                path = args.render_directory / filename
                if not path.is_file():
                    failures.append(f"Missing fixture: {filename}")
                    continue
                with Image.open(path) as source:
                    image = source.convert("RGB")
                scale = image.width / 373
                if image.height != round(440 * scale) or scale < 1:
                    failures.append(f"Unexpected fixture dimensions: {filename} {image.size}")
                    continue
                reference, marks = inspect_marks(image, scale)
                invalid = [mark["index"] for mark in marks if not mark["visible"]]
                if invalid:
                    failures.append(f"Filled records not visible: {filename}: {invalid}")
                entry["files"].append({"name": filename, "size": list(image.size),
                                       "alarm_title_contrast": reference,
                                       "visible_marks": 12 - len(invalid), "marks": marks})
                # Inset by 1 pt from the exclusion boundary, preserving all
                # record text/marks while excluding clip-edge antialiasing.
                images.append(image.crop(point_box((267, 63, 353, 119), scale)))
            if len(images) == 2:
                if images[0].size != images[1].size:
                    failures.append(f"Mismatched image scales: {stem}")
                else:
                    difference = ImageChops.difference(*images)
                    pixels = list(pixel_data(difference))
                    changed = sum(any(pixel) for pixel in pixels)
                    maximum = max(max(pixel) for pixel in pixels)
                    mean = sum(sum(pixel) for pixel in pixels) / (len(pixels) * 3)
                    entry.update({"compared_pixels": len(pixels), "changed_pixels": changed,
                                  "max_channel_difference": maximum,
                                  "mean_channel_difference": round(mean, 6)})
                    if changed:
                        failures.append(f"Geometry entered reserved gutter: {stem}: "
                                        f"{changed} changed pixels, maximum channel delta {maximum}")
            pairs.append(entry)
    files = [item for pair in pairs for item in pair["files"]]
    summary = {"scope": "Self-heal gutter only; no whole-page visual acceptance implied",
               "expected_images": 8, "checked_images": len(files),
               "expected_pairs": 4,
               "compared_pairs": sum("changed_pixels" in pair for pair in pairs),
               "expected_visible_marks": 96,
               "visible_marks": sum(item["visible_marks"] for item in files),
               "pairs": pairs, "failures": failures, "passed": not failures}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    for pair in pairs:
        if "changed_pixels" in pair:
            print(f"{pair['pair']}: changed={pair['changed_pixels']}/{pair['compared_pixels']} pixels, "
                  f"max_delta={pair['max_channel_difference']}, "
                  f"visible_marks={sum(item['visible_marks'] for item in pair['files'])}/24")
    for failure in failures:
        print(f"FAIL: {failure}")
    print(f"{'PASS' if not failures else 'FAIL'}: {len(files)}/8 images, "
          f"{summary['compared_pairs']}/4 gutter pairs, {summary['visible_marks']}/96 filled marks")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

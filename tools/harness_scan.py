#!/usr/bin/env python3
"""Bounding box of a marker colour in a harness screenshot.

    harness_scan.py <shot.png> <green|red|blue|white|magenta>

Prints "x_min y_min x_max y_max pixel_count" in PNG coordinates (y down from
the top-left), or "none" when the colour is absent.

The harness shader (tools/harness_probe.frag) paints in pure primaries, so a
generous per-channel tolerance still cannot confuse one marker for another.

Coordinate note: the daemon flips into GL space (y up) and grim writes PNG rows
top-down, so the two flips cancel. A window at monitor-local (wx, wy, w, h)
must therefore produce a green ring whose bbox is exactly
(wx-14, wy-14) .. (wx+w+14, wy+h+14) -- PAD 12 + TH 2 from the shader.
"""

import sys

import numpy as np
from PIL import Image

KEYS = {
    "green": (0, 255, 0),
    "red": (255, 0, 0),
    "blue": (0, 0, 255),
    "white": (255, 255, 255),
    "magenta": (255, 0, 255),
}


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[2] not in KEYS:
        print(f"usage: {sys.argv[0]} <shot.png> <{'|'.join(KEYS)}>", file=sys.stderr)
        return 2

    img = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
    mask = (np.abs(img - np.array(KEYS[sys.argv[2]])) < 40).all(axis=2)

    if not mask.any():
        print("none")
        return 0

    ys, xs = np.nonzero(mask)
    print(f"{xs.min()} {ys.min()} {xs.max()} {ys.max()} {mask.sum()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

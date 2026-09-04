#!/usr/bin/env python3

from pathlib import Path
import sys

from PIL import Image


def main() -> int:
    if len(sys.argv) != 3:
        print("用法：png_to_icns.py <输入 PNG> <输出 ICNS>", file=sys.stderr)
        return 2

    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    with Image.open(source) as image:
        image.save(destination, format="ICNS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

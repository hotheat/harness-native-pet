#!/usr/bin/env python3
"""Render the checked-in SVG artwork into native macOS icon resources."""
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    source = root / 'designs/icons'
    output = root / 'native/Sources/DSHNativePet/Resources/Icons'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='dnp-icons-') as temporary:
        iconset = Path(temporary) / 'AppIcon.iconset'
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
                pixels = str(size * scale)
                subprocess.run(['rsvg-convert', '-w', pixels, '-h', pixels,
                                str(source / 'app-icon.svg'), '-o', str(iconset / name)], check=True)
        subprocess.run(['iconutil', '-c', 'icns', str(iconset),
                        '-o', str(output / 'AppIcon.icns')], check=True)
    subprocess.run(['rsvg-convert', '-f', 'pdf', '--dpi-x', '72', '--dpi-y', '72',
                    str(source / 'menu-bar.svg'), '-o', str(output / 'MenuBarTemplate.pdf')], check=True)
    print(output)


if __name__ == '__main__':
    main()

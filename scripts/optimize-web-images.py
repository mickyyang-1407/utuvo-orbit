"""Encode web-only derivatives. Requires cwebp (libwebp); originals stay intact."""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
assets = root / 'docs/assets'
encoder = shutil.which('cwebp')
if not encoder:
    raise SystemExit('cwebp is required. On macOS: brew install webp')


def encode(source, target, quality, width=None):
    args = [encoder, '-quiet', '-m', '6', '-q', str(quality),
            '-sharp_yuv', '-metadata', 'none']
    if width:
        args += ['-resize', str(width), '0']
    subprocess.run(args + [str(assets / source), '-o', str(assets / target)], check=True)
    print(f'{target}: {(assets / target).stat().st_size:,} bytes')


for width in (640, 960, 1280, 1672):
    encode('orbit-hero-gold.png', f'orbit-hero-gold-{width}.webp', 86, width)
encode('app-icon.png', 'app-icon-80.webp', 92, 80)
for name in ('overview-dark', 'overview-light', 'network-light', 'peripherals-dark'):
    for language in ('', '-en'):
        stem = name + language
        encode(stem + '.png', stem + '.webp', 92)

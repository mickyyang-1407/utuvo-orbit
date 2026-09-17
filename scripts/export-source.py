"""Curated source export. Never package the entire working directory."""
import shutil
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
target = Path(sys.argv[1]).resolve()
target.mkdir(parents=True, exist_ok=True)
files = [
    'Package.swift', 'LICENSE', 'README.md', 'README.zh-Hant.md',
    'CONTRIBUTING.md', 'SECURITY.md', 'NOTICE.md', 'CHANGELOG.md', '.gitignore',
    'Resources/AppIcon.icns', 'Resources/app-icon.png',
    'scripts/build-app.sh', 'scripts/render-brand.swift', 'scripts/render-release-art.swift',
    'scripts/package-release.sh', 'scripts/dmg-layout.py', 'scripts/export-source.py',
    'scripts/optimize-web-images.py',
    'docs/INSTALL.md', 'docs/USER-GUIDE.md', 'docs/USER-GUIDE.zh-Hant.md',
    'docs/DEVELOPMENT.md', 'docs/LAUNCH-COPY.md',
]
directories = ['Sources/OrbitCore', 'Sources/UtuvoOrbit', 'Tests', '.github',
               'docs/assets', 'docs/releases', 'docs/showcase']
for item in files:
    dest = target / item
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / item, dest)
for item in directories:
    shutil.copytree(root / item, target / item, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('.DS_Store', '__pycache__'))

# GitHub Pages publishes /docs. Keep the English root entry derived from the
# editable showcase so the root URL and the local preview share one source.
homepage = (root / 'docs/showcase/en.html').read_text()
homepage = homepage.replace('../assets/', 'assets/')
homepage = homepage.replace('href="index.html"', 'href="showcase/index.html"')
(target / 'docs/index.html').write_text(
    '<!-- Generated from docs/showcase/en.html by scripts/export-source.py. -->\n'
    + homepage)
(target / 'docs/.nojekyll').touch()
print(f'Source export: {target}')

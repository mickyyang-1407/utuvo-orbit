"""Curated source export. Never package the entire working directory.

The export is an explicit allow-list, so internal material (handoffs, review
notes, evidence, build output, the retired PikOrbit app and private signing
material) can never leak into it by accident.
"""
import shutil
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
target = Path(sys.argv[1]).resolve()
target.mkdir(parents=True, exist_ok=True)

# Buildable implementation, dependency metadata, licences and user docs.
files = [
    'Package.swift', 'Package.resolved', 'project.yml',
    'LICENSE', 'README.md', 'README.zh-Hant.md',
    'CONTRIBUTING.md', 'SECURITY.md', 'NOTICE.md', 'CHANGELOG.md', '.gitignore',
    'Resources/AppIcon.icns', 'Resources/app-icon.png', 'Resources/UpdateConfiguration.plist', 'Resources/Sparkle-LICENSE',
    'scripts/build-app.sh', 'scripts/render-brand.swift', 'scripts/render-release-art.swift',
    'scripts/package-release.sh', 'scripts/dmg-layout.py', 'scripts/export-source.py', 'scripts/sign-app.sh',
    'scripts/optimize-web-images.py',
    'scripts/prepare-update.py', 'docs/UPDATING.md',
    'docs/INSTALL.md', 'docs/USER-GUIDE.md', 'docs/USER-GUIDE.zh-Hant.md', 'docs/TOOLS.md', 'docs/TOOLS-SCREENSHOTS.md',
    'docs/DEVELOPMENT.md', 'docs/LAUNCH-COPY.md',
    # Mac App Store build: source, shims, tests, assets, entitlements.
    'MAS/Info.plist', 'MAS/UTUVOOrbitMAS.entitlements', 'MAS/ExportOptions-AppStore.plist',
]
directories = [
    'Sources/OrbitCore', 'Sources/UtuvoOrbit', 'Sources/ShelfKit', 'Sources/ClotheslineKit',
    'Tests', '.github',
    'MAS/Sources', 'MAS/Tests', 'MAS/Shims', 'MAS/ShelfKitShims', 'MAS/Assets.xcassets',
    'docs/assets', 'docs/releases', 'docs/showcase',
]

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

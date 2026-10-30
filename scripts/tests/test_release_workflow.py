#!/usr/bin/env python3
"""Packaging-orchestration fixtures for the release workflow.

The real ``scripts/package-release.sh``, ``scripts/build-app.sh`` and
``scripts/check-version.py`` are executed against a synthetic repository tree.
These are ORCHESTRATION fixtures only:

* ``codesign``, ``lipo`` and ``hdiutil`` are replaced by pure fake command
  line tools — no signing, no keychain, no notarization, no disk image is
  ever created, mounted or detached;
* ``scripts/dmg-layout.py`` is never really executed; ``PACKAGING_PYTHON``
  points at a fake interpreter;
* the ``.app`` is a fixture bundle, not a build of Orbit;
* the source export runs against the fixture tree, never against the real
  repository working tree.

Nothing here proves that a real signature, a real disk image layout or a real
notarization is correct. What the fixtures prove is the workflow contract:
existing artifacts and symlinks are refused instead of overwritten, a prepared
update ZIP is reused byte for byte, and a build is blocked when the shipped
version defaults drift apart.
"""
import ast
import base64
import hashlib
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
VERSION = '0.12.1'
BUILD_NUMBER = '18'
STEM = f'UTUVO-Orbit-{VERSION}-arm64'
SOURCE_ZIP_NAME = f'utuvo-orbit-{VERSION}-source.zip'
CHECKSUMS_NAME = 'SHA256SUMS.txt'
APP_ZIP_NAME = f'{STEM}.zip'
DMG_NAME = f'{STEM}.dmg'

FIXTURE_CLIS = {
    'codesign': '#!/bin/sh\n# Fixture fake for codesign: no signing, no verification.\nexit 0\n',
    'lipo': '#!/bin/sh\n# Fixture fake for lipo: no architecture inspection.\nexit 0\n',
    'swift': ('#!/bin/sh\n# Fixture fake for swift: records that a build was attempted.\n'
              ': > "$SWIFT_MARKER"\nexit 0\n'),
    'fake-python': ('#!/bin/sh\n# Fixture fake interpreter: scripts/dmg-layout.py never runs.\n'
                    'exit 0\n'),
}

HDIUTIL_FAKE = """#!/bin/sh
# Fixture fake for hdiutil: never creates, attaches or detaches a real image.
command="$1"
shift
case "$command" in
  create)
    for last in "$@"; do :; done
    if [ -n "$last" ]; then : > "$last"; fi
    ;;
  convert)
    output=""
    previous=""
    for argument in "$@"; do
      if [ "$previous" = "-o" ]; then output="$argument"; fi
      previous="$argument"
    done
    if [ -n "$output" ]; then : > "$output"; fi
    ;;
esac
exit 0
"""


def export_allowlist(script_path):
    """Read the file and directory allow-lists out of scripts/export-source.py."""
    files, directories = [], []
    tree = ast.parse(script_path.read_text(encoding='utf-8'))
    for node in tree.body:
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.List):
            continue
        names = [target.id for target in node.targets if isinstance(target, ast.Name)]
        values = [ast.literal_eval(element) for element in node.value.elts]
        if 'files' in names:
            files = values
        elif 'directories' in names:
            directories = values
    return files, directories


@unittest.skipUnless(os.uname().machine == 'arm64', 'the packaging script only runs on arm64')
class ReleaseWorkflowTest(unittest.TestCase):

    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix='orbit-release-fixture.'))
        self.addCleanup(shutil.rmtree, self.base, True)
        self.root = self.base / 'repo'
        self.build_fixture()

    # ---------------------------------------------------------------- fixture

    def build_fixture(self):
        root = self.root
        (root / 'scripts').mkdir(parents=True)
        for name in ('build-app.sh', 'package-release.sh', 'prepare-update.py',
                     'dmg-layout.py', 'export-source.py', 'check-version.py'):
            shutil.copy2(REPO / 'scripts' / name, root / 'scripts' / name)

        files, directories = export_allowlist(REPO / 'scripts' / 'export-source.py')
        for name in files:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists():
                path.write_text('fixture\n')
        for name in directories:
            (root / name).mkdir(parents=True, exist_ok=True)

        # The version sources the checker reads, with the shipped defaults.
        (root / 'project.yml').write_text(
            'MARKETING_VERSION: "0.12.1"\nCURRENT_PROJECT_VERSION: "18"\n')
        (root / 'Sources/UtuvoOrbit').mkdir(parents=True, exist_ok=True)
        (root / 'Sources/UtuvoOrbit/OrbitStyle.swift').write_text(
            'let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")'
            ' as? String ?? "0.12.1"\n'
            'let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")'
            ' as? String ?? "18"\n')
        (root / 'Sources/UtuvoOrbit/OrbitPanel.swift').write_text(
            'Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")'
            ' as? String ?? "0.12.1")\n')

        # The exported showcase page and the disk image background are read.
        (root / 'docs/showcase').mkdir(parents=True, exist_ok=True)
        (root / 'docs/showcase/en.html').write_text('<html><body>fixture</body></html>\n')
        (root / 'docs/assets').mkdir(parents=True, exist_ok=True)
        (root / 'docs/assets/dmg-background.png').write_bytes(b'\x89PNG fixture\n')

        # The public fixture test travels with the exported source.
        (root / 'scripts/tests').mkdir(parents=True, exist_ok=True)
        shutil.copy2(Path(__file__), root / 'scripts/tests' / Path(__file__).name)

        self.bin = self.base / 'bin'
        self.bin.mkdir()
        for name, body in FIXTURE_CLIS.items():
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)
        hdiutil = self.bin / 'hdiutil'
        hdiutil.write_text(HDIUTIL_FAKE)
        hdiutil.chmod(0o755)
        (self.base / 'tmp').mkdir()

    def make_app(self):
        app = self.root / 'dist' / 'UTUVO Orbit.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Frameworks/Sparkle.framework').mkdir(parents=True)
        (app / 'Contents/MacOS/UtuvoOrbit').write_bytes(b'fixture executable\n')
        (app / 'Contents/Frameworks/Sparkle.framework/Sparkle').write_bytes(b'fixture framework\n')
        info = {
            'CFBundleIdentifier': 'com.utuvo.orbit',
            'CFBundleShortVersionString': VERSION,
            'CFBundleVersion': BUILD_NUMBER,
            'NSScreenCaptureUsageDescription': 'Fixture bundle for packaging tests.',
            'SUFeedURL': 'https://example.invalid/updates/appcast.xml',
            # A dummy 32-byte value generated in the test. It is not a key.
            'SUPublicEDKey': base64.b64encode(bytes(32)).decode('ascii'),
            'SUVerifyUpdateBeforeExtraction': True,
            'SURequireSignedFeed': True,
        }
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        return app

    def environment(self, **extra):
        env = os.environ.copy()
        env['PATH'] = f'{self.bin}{os.pathsep}{env.get("PATH", "")}'
        env['PACKAGING_PYTHON'] = str(self.bin / 'fake-python')
        env['SKIP_BUILD'] = '1'
        env['TMPDIR'] = str(self.base / 'tmp') + '/'
        env['SWIFT_MARKER'] = str(self.base / 'swift-ran')
        env.pop('VERSION', None)
        env.pop('BUILD_NUMBER', None)
        env.update(extra)
        return env

    def run_script(self, name, **extra):
        return subprocess.run(['bash', str(self.root / 'scripts' / name)],
                              cwd=self.root, env=self.environment(**extra),
                              capture_output=True, text=True)

    def run_checker(self, **extra):
        return subprocess.run([sys.executable, str(self.root / 'scripts/check-version.py')],
                              cwd=self.root, env=self.environment(**extra),
                              capture_output=True, text=True)

    def release_dir(self):
        return self.root / 'release' / VERSION

    def artifact(self, name):
        return self.release_dir() / name

    def write_prepared_zip(self):
        """Create the authoritative update ZIP the way prepare-update.py would."""
        path = self.artifact(APP_ZIP_NAME)
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('UTUVO Orbit.app/Contents/Info.plist', 'fixture\n')
        return path

    # ------------------------------------------------------------------ tests

    def test_default_packaging_creates_every_artifact(self):
        app = self.make_app()
        result = self.run_script('package-release.sh', APP_PATH=str(app))
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in (APP_ZIP_NAME, DMG_NAME, SOURCE_ZIP_NAME, CHECKSUMS_NAME):
            self.assertTrue(self.artifact(name).is_file(), f'{name} was not created')

    def test_existing_artifact_is_refused_and_preserved(self):
        app = self.make_app()
        for name in (APP_ZIP_NAME, DMG_NAME, SOURCE_ZIP_NAME, CHECKSUMS_NAME):
            with self.subTest(artifact=name):
                release = self.release_dir()
                if release.exists():
                    for entry in release.iterdir():
                        entry.unlink()
                path = self.artifact(name)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'previous bytes')
                before = (path.read_bytes(), path.stat().st_mtime_ns)
                result = self.run_script('package-release.sh', APP_PATH=str(app))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('refusing to overwrite', result.stderr)
                after = (path.read_bytes(), path.stat().st_mtime_ns)
                self.assertEqual(before, after, 'the previous artifact was modified')
                self.assertEqual(sorted(entry.name for entry in release.iterdir()), [name],
                                 'the refused run wrote additional artifacts')

    def test_symlinked_artifact_is_refused(self):
        app = self.make_app()
        outside = self.base / 'outside.bin'
        outside.write_bytes(b'outside\n')
        link = self.artifact(DMG_NAME)
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(outside)
        result = self.run_script('package-release.sh', APP_PATH=str(app))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('symlink', result.stderr)
        self.assertTrue(link.is_symlink())
        self.assertEqual(outside.read_bytes(), b'outside\n')

    def test_skip_app_zip_without_prepared_zip_is_refused(self):
        app = self.make_app()
        result = self.run_script('package-release.sh', APP_PATH=str(app), SKIP_APP_ZIP='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('needs the prepared update ZIP', result.stderr)
        self.assertFalse(self.release_dir().exists(), 'a refused run created the release folder')

    def test_skip_app_zip_with_symlinked_zip_is_refused(self):
        app = self.make_app()
        outside = self.base / 'outside.zip'
        outside.write_bytes(b'PK not really\n')
        link = self.artifact(APP_ZIP_NAME)
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(outside)
        result = self.run_script('package-release.sh', APP_PATH=str(app), SKIP_APP_ZIP='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('symlink', result.stderr)
        self.assertTrue(link.is_symlink())

    def test_skip_app_zip_preserves_the_prepared_zip(self):
        app = self.make_app()
        prepared = self.write_prepared_zip()
        before_bytes = prepared.read_bytes()
        before_stat = prepared.stat()
        result = self.run_script('package-release.sh', APP_PATH=str(app), SKIP_APP_ZIP='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(prepared.read_bytes(), before_bytes, 'the prepared ZIP bytes changed')
        self.assertEqual(prepared.stat().st_mtime_ns, before_stat.st_mtime_ns,
                         'the prepared ZIP mtime changed')
        self.assertEqual(prepared.stat().st_size, before_stat.st_size)
        for name in (DMG_NAME, SOURCE_ZIP_NAME, CHECKSUMS_NAME):
            self.assertTrue(self.artifact(name).is_file(), f'{name} was not created')
        sums = self.artifact(CHECKSUMS_NAME).read_text()
        self.assertIn(APP_ZIP_NAME, sums)
        self.assertIn(hashlib.sha256(before_bytes).hexdigest(), sums)

    def test_version_check_accepts_the_shipped_defaults(self):
        result = self.run_checker()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(VERSION, result.stdout)

    def test_environment_override_is_not_drift(self):
        result = self.run_checker(VERSION='9.9.9', BUILD_NUMBER='999')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('override', result.stdout)

    def test_version_drift_in_project_is_rejected(self):
        project = self.root / 'project.yml'
        project.write_text(project.read_text().replace('MARKETING_VERSION: "0.12.1"',
                                                       'MARKETING_VERSION: "0.12.2"'))
        result = self.run_checker()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('inconsistent', result.stdout + result.stderr)

    def test_version_drift_in_build_script_is_rejected(self):
        script = self.root / 'scripts/build-app.sh'
        script.write_text(script.read_text().replace('BUILD_NUMBER:-18', 'BUILD_NUMBER:-19'))
        result = self.run_checker()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('inconsistent', result.stdout + result.stderr)

    def test_build_is_blocked_before_any_build_step(self):
        project = self.root / 'project.yml'
        project.write_text(project.read_text().replace('MARKETING_VERSION: "0.12.1"',
                                                       'MARKETING_VERSION: "0.12.2"'))
        result = self.run_script('build-app.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Build blocked', result.stderr)
        self.assertFalse((self.base / 'swift-ran').exists(),
                         'the build continued after the version check failed')


if __name__ == '__main__':
    unittest.main()

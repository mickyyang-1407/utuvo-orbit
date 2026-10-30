#!/usr/bin/env python3
"""Fail closed when the shipped version/build defaults drift apart.

Exactly four known fields are read, each with its own narrow pattern:

  version  scripts/build-app.sh          VERSION default
           project.yml                    MARKETING_VERSION
           Sources/UtuvoOrbit/OrbitStyle.swift   CFBundleShortVersionString fallback
           Sources/UtuvoOrbit/OrbitPanel.swift   CFBundleShortVersionString fallback
  build    scripts/build-app.sh          BUILD_NUMBER default
           project.yml                    CURRENT_PROJECT_VERSION
           Sources/UtuvoOrbit/OrbitStyle.swift   CFBundleVersion fallback

Nothing else is scanned: no changelog, no release history, no blanket search
for version-like strings. A field that is absent (file missing, or the literal
removed) is skipped rather than guessed at.

The VERSION / BUILD_NUMBER environment overrides are deliberately ignored
here. They change one local build only — a test bundle, a branch build — and
must never be mistaken for drift between the sources of truth. The file
defaults are what ships, so the file defaults are what gets compared.

Exit codes: 0 consistent, 1 drift detected, 2 usage or unreadable input.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

VERSION_SOURCES = [
    ('scripts/build-app.sh', re.compile(r'VERSION="\$\{VERSION:-([^}]*)\}"')),
    ('project.yml', re.compile(r'^[ \t]*MARKETING_VERSION:[ \t]*"?([^"#\s]+)"?[ \t]*$', re.M)),
    ('Sources/UtuvoOrbit/OrbitStyle.swift',
     re.compile(r'CFBundleShortVersionString.*?\?\?[ \t]*"([^"]*)"')),
    ('Sources/UtuvoOrbit/OrbitPanel.swift',
     re.compile(r'CFBundleShortVersionString.*?\?\?[ \t]*"([^"]*)"')),
]

BUILD_SOURCES = [
    ('scripts/build-app.sh', re.compile(r'BUILD_NUMBER="\$\{BUILD_NUMBER:-([^}]*)\}"')),
    ('project.yml', re.compile(r'^[ \t]*CURRENT_PROJECT_VERSION:[ \t]*"?([^"#\s]+)"?[ \t]*$', re.M)),
    ('Sources/UtuvoOrbit/OrbitStyle.swift',
     re.compile(r'CFBundleVersion.*?\?\?[ \t]*"([^"]*)"')),
]


class DriftError(Exception):
    """Raised when the known version fields disagree."""


def read_source(root, label, pattern):
    """Return the single value declared by one source, or None when absent."""
    path = root / label
    if not path.is_file():
        return None
    try:
        text = path.read_text(encoding='utf-8', errors='replace')
    except OSError as error:
        raise DriftError(f'{label} could not be read: {error}') from error
    values = []
    for match in pattern.finditer(text):
        value = match.group(1).strip()
        if value:
            values.append(value)
    if not values:
        return None
    distinct = sorted(set(values))
    if len(distinct) > 1:
        raise DriftError(f'{label} declares more than one value: {", ".join(distinct)}')
    return distinct[0]


def collect(root, sources):
    found = {}
    for label, pattern in sources:
        value = read_source(root, label, pattern)
        if value is not None:
            found[label] = value
    return found


def compare(field, found):
    """Return (ok, message) for one field."""
    if not found:
        return True, f'{field}: no known source declares it (skipped)'
    values = sorted(set(found.values()))
    if len(values) > 1:
        detail = ', '.join(f'{label}={value}' for label, value in sorted(found.items()))
        return False, f'{field}: inconsistent ({detail})'
    label = next(iter(found))
    sources = ', '.join(sorted(found))
    return True, f'{field}: {values[0]} [{sources}]'


def main(argv=None):
    parser = argparse.ArgumentParser(description='Check the shipped version defaults for drift.')
    parser.add_argument('--root', type=Path, default=ROOT,
                        help='Repository root to read (default: the parent of scripts/).')
    parser.add_argument('--json', action='store_true', help='Emit a machine-readable report.')
    args = parser.parse_args(argv)

    root = args.root.resolve()
    if not root.is_dir():
        print(f'version check failed: {root} is not a directory', file=sys.stderr)
        return 2

    overrides = [name for name in ('VERSION', 'BUILD_NUMBER') if os.environ.get(name)]
    try:
        version_found = collect(root, VERSION_SOURCES)
        build_found = collect(root, BUILD_SOURCES)
        version_ok, version_line = compare('version', version_found)
        build_ok, build_line = compare('build', build_found)
    except DriftError as error:
        print(f'version check failed: {error}', file=sys.stderr)
        return 1

    ok = version_ok and build_ok
    report = {
        'ok': ok,
        'version': {'ok': version_ok, 'values': version_found},
        'build': {'ok': build_ok, 'values': build_found},
        'environment_overrides': overrides,
    }
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for line in (version_line, build_line):
            print(line)
        if overrides:
            print('note: environment override in effect (' + ', '.join(overrides) +
                  '); only the file defaults are compared.')
        if ok:
            print('OK: version defaults are consistent.')
        else:
            print('FAILED: version defaults drifted.', file=sys.stderr)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())

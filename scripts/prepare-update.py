#!/usr/bin/env python3
"""Validate and prepare a signed Sparkle release locally. Never uploads anything."""
import argparse
import base64
import hashlib
import json
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from urllib.parse import urlparse
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def https_url(value):
    url = urlparse(value)
    if url.scheme != 'https' or not url.hostname or url.username or url.password:
        raise ValueError('A credential-free HTTPS URL is required.')
    return url


def validate_app(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.utuvo.orbit':
        raise ValueError('Only the direct-download Orbit bundle may use Sparkle.')
    if not str(info.get('NSScreenCaptureUsageDescription', '')).strip():
        raise ValueError('Native screenshots require a screen-capture usage description.')
    https_url(info.get('SUFeedURL', ''))
    if len(base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)) != 32:
        raise ValueError('The production Ed25519 public key is missing or invalid.')
    if not info.get('SUVerifyUpdateBeforeExtraction'):
        raise ValueError('Updates must be signature-verified before extraction.')
    if not info.get('SURequireSignedFeed'):
        raise ValueError('The release appcast must be signature-verified.')
    if not (app / 'Contents/Frameworks/Sparkle.framework/Sparkle').is_file():
        raise ValueError('Sparkle.framework is missing.')
    return info


def prepare(args):
    app = args.app.resolve()
    info = validate_app(app)
    url = https_url(args.download_url)
    if not url.path.endswith('.zip'):
        raise ValueError('The download URL must name the update ZIP.')
    signer = ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
    key_lookup = signer.with_name('generate_keys')
    signing_public_key = subprocess.check_output([str(key_lookup), '--account', args.account, '-p'], text=True).strip()
    if signing_public_key != info['SUPublicEDKey']:
        raise ValueError('The signing account does not match the public key embedded in this app.')
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], capture_output=True, text=True, check=True).stderr
    if 'Authority=Developer ID Application:' not in signature or 'TeamIdentifier=RPNT54P79S' not in signature:
        raise ValueError('A UTUVO Developer ID signed app is required for a release feed.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / Path(url.path).name
    if archive.exists():
        raise ValueError(f'Refusing to overwrite an existing release archive: {archive.name}')
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
    sign_args = [str(signer), '--account', args.account]
    signed = subprocess.run([*sign_args, '-p', str(archive)], capture_output=True, text=True, check=True).stdout.strip()
    if len(base64.b64decode(signed, validate=True)) != 64:
        raise ValueError('Signer did not return a valid Ed25519 signature.')
    subprocess.run([*sign_args, '--verify', str(archive), signed], check=True)
    feed = output / 'appcast.xml'
    if feed.exists():
        subprocess.run([*sign_args, '--verify', str(feed)], check=True)
        tree = ET.parse(feed)
        channel = tree.getroot().find('channel')
        if channel is None:
            raise ValueError('Existing appcast has no channel.')
    else:
        root = ET.Element('rss', version='2.0')
        channel = ET.SubElement(root, 'channel')
        ET.SubElement(channel, 'title').text = 'UTUVO Orbit updates'
        ET.SubElement(channel, 'link').text = 'https://mickyyang-1407.github.io/utuvo-orbit/'
        tree = ET.ElementTree(root)
    build = info['CFBundleVersion']
    if any(item.findtext(f'{{{SPARKLE}}}version') == build for item in channel.findall('item')):
        raise ValueError('This build is already present in the appcast.')
    item = ET.Element('item')
    ET.SubElement(item, 'title').text = f"UTUVO Orbit {info['CFBundleShortVersionString']}"
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = build
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = info['CFBundleShortVersionString']
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = '14.0.0'
    ET.SubElement(item, f'{{{SPARKLE}}}hardwareRequirements').text = 'arm64'
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, 'description').text = args.notes.read_text()
    ET.SubElement(item, 'enclosure', {'url': args.download_url, 'length': str(archive.stat().st_size),
                                   'type': 'application/octet-stream', f'{{{SPARKLE}}}edSignature': signed})
    channel.insert(2, item)
    ET.indent(tree, space='  ')
    # The signer inserts the signed-feed declaration after XML serialization.
    tree.write(feed, encoding='utf-8', xml_declaration=True)
    subprocess.run([*sign_args, str(feed)], check=True)
    subprocess.run([*sign_args, '--verify', str(feed)], check=True)
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [archive, feed]}
    (output / 'update-sha256.json').write_text(json.dumps(hashes, indent=2) + '\n')
    print(f'Signed update candidate ready in {output}. Nothing has been uploaded.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    validate = commands.add_parser('validate-app')
    validate.add_argument('app', type=Path)
    create = commands.add_parser('create')
    create.add_argument('--app', type=Path, required=True)
    create.add_argument('--output', type=Path, required=True)
    create.add_argument('--download-url', required=True)
    create.add_argument('--notes', type=Path, required=True)
    create.add_argument('--account', default='com.utuvo.orbit.sparkle')
    args = parser.parse_args()
    try:
        if args.command == 'validate-app':
            validate_app(args.app)
            print('Update configuration and embedded framework verified.')
        else:
            prepare(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'Update preparation failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

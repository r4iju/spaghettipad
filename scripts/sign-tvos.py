#!/usr/bin/env python3
"""Sign a local tvOS app with an existing development profile and Keychain identity."""
import argparse
import datetime
import hashlib
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('profile', type=Path)
parser.add_argument('--device', help='Require this Apple TV UDID in the profile')
args = parser.parse_args()
profile = plistlib.loads(subprocess.check_output(
    ['security', 'cms', '-D', '-i', str(args.profile)], stderr=subprocess.DEVNULL))
info = plistlib.loads((args.app / 'Info.plist').read_bytes())
entitlements = profile['Entitlements']
if 'tvOS' not in profile.get('Platform', []) or not entitlements.get('get-task-allow'):
    raise SystemExit('A tvOS development profile is required')
if entitlements['application-identifier'].split('.', 1)[1] != info['CFBundleIdentifier']:
    raise SystemExit('Profile does not match the app bundle identifier')
if profile['ExpirationDate'] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    raise SystemExit('Profile expired')
if args.device and args.device not in profile.get('ProvisionedDevices', []):
    raise SystemExit('Profile does not include this Apple TV')
identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning']).decode()
matches = [hashlib.sha1(bytes(cert)).hexdigest().upper()
           for cert in profile['DeveloperCertificates']]
identity = next((digest for digest in matches if digest in identities), None)
if not identity:
    raise SystemExit('No Keychain signing identity matches the profile')
(args.app / 'embedded.mobileprovision').write_bytes(args.profile.read_bytes())
path = args.app.parent / 'signing.entitlements'
path.write_bytes(plistlib.dumps(entitlements))
subprocess.run(['codesign', '--force', '--sign', identity, '--entitlements', str(path),
                str(args.app)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(args.app)], check=True)
print(f'Signed local app: {args.app}')

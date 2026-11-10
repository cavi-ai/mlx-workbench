"""Sign and replace the installed application, then probe that exact copy."""
import argparse
import hashlib
import json
import plistlib
import subprocess
import tempfile
from pathlib import Path

TARGET = Path('/Applications/MLX Workbench.app')
MAGIC = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
         b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
         b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def run(argv):
    return subprocess.run(argv, check=True, capture_output=True, text=True, timeout=30)


def info(app):
    if not app.is_absolute() or app.is_symlink() or app.resolve() != app:
        raise ValueError('Select a canonical application directory.')
    value = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if value.get('CFBundleIdentifier') != 'com.cavi.mlxworkbench':
        raise ValueError('The selected application is not MLX Workbench.')
    return value


def binaries(app):
    result = []
    for path in app.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream:
                if stream.read(4) in MAGIC:
                    result.append(path)
    return sorted(result, key=lambda path: (-len(path.parts), str(path)))


def signature(path):
    result = run(['codesign', '-dvv', str(path)])
    fields = dict(line.split('=', 1) for line in result.stderr.splitlines() if '=' in line)
    team = fields.get('TeamIdentifier')
    return {'team': None if team == 'not set' else team}


def verify_teams(app, team, inspect=signature):
    if not team:
        raise ValueError('A signed installed application with a Team ID is required.')
    for path in [*binaries(app), app]:
        if inspect(path).get('team') != team:
            raise ValueError('Application signing Team ID differs for ' + str(path))


def sign_app(app, identity, entitlements, run=run):
    executable = app / 'Contents/MacOS' / info(app)['CFBundleExecutable']
    common = ['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp=none']
    for path in binaries(app):
        if path != executable:
            run([*common, str(path)])
    nested = [path for path in app.rglob('*') if path.is_dir() and not path.is_symlink()
              and path.suffix in ('.framework', '.xctest', '.app')]
    for path in sorted(nested, key=lambda item: -len(item.parts)):
        run([*common, str(path)])
    run([*common, *(['--entitlements', str(entitlements)] if entitlements else []), str(app)])


def probe(app):
    metadata = info(app)
    if metadata.get('MLXWorkbenchInstallationProbe') != 1:
        raise ValueError('This build has no headless installation-check protocol; it will not be launched.')
    executable = app / 'Contents/MacOS' / metadata['CFBundleExecutable']
    result = run([str(executable), '--check-installation'])
    value = json.loads(result.stdout)
    if value.get('protocol') != 'workbench-installation/1' or value.get('application') != str(app):
        raise ValueError('The installation check did not run the selected application.')
    return value


def install(app, target):
    info(app)
    info(target)
    team = signature(target)['team']
    if not team:
        raise ValueError('Preserve the installed signing identity; an unsigned replacement is not supported.')
    with tempfile.TemporaryDirectory(prefix='mlx-workbench-sign-') as directory:
        root = Path(directory)
        run(['codesign', '-d', '--extract-certificates=' + str(root / 'certificate-'), str(target)])
        result = run(['openssl', 'x509', '-inform', 'DER', '-in', str(root / 'certificate-0'),
                      '-noout', '-fingerprint', '-sha1'])
        identity = result.stdout.strip().split('=')[-1].replace(':', '')
        if len(identity) != 40:
            raise ValueError('The installed signing certificate could not be identified.')
        entitlements = root / 'entitlements.plist'
        entitlements.write_text(run(['codesign', '-d', '--entitlements', ':-', str(target)]).stdout)
        sign_app(app, identity, entitlements)
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    verify_teams(app, team)
    probe(app)
    run(['rsync', '-a', '--delete', str(app) + '/', str(target) + '/'])
    run(['codesign', '--verify', '--deep', '--strict', str(target)])
    verify_teams(target, team)
    result = probe(target)
    name = info(app)['CFBundleExecutable']
    with (app / 'Contents/MacOS' / name).open('rb') as stream:
        expected = hashlib.file_digest(stream, 'sha256').hexdigest()
    with (target / 'Contents/MacOS' / name).open('rb') as stream:
        actual = hashlib.file_digest(stream, 'sha256').hexdigest()
    if expected != actual:
        raise ValueError('The installed executable differs from the checked build.')
    return {'application': str(target), 'executable_sha256': actual, 'team': team, 'probe': result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--target', type=Path, default=TARGET)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    try:
        if args.check_only:
            info(args.app)
            verify_teams(args.app, signature(args.app)['team'])
            result = probe(args.app)
        else:
            result = install(args.app, args.target)
        print(json.dumps(result, indent=2))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__': main()

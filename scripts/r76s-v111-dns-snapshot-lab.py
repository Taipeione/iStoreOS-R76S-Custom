#!/usr/bin/env python3
"""V1.1.1 multi-file DNS snapshot/rollback *laboratory*, never a router tool.

Only operates inside a preexisting /tmp/r76s-v111-lab.<alphanumeric>/ directory.
No network, UCI, daemon operations, /etc writes, credentials logging or runtime installation.
It models snapshots, multi-file staging, external-edit detection and crash recovery.
The lab DOES NOT prove correct DNS configuration syntax or live transition safety.
"""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

FILES = ('dhcp.conf', 'adguardhome.yaml', 'passwall-dnsmasq.conf', 'smartdns.conf')
ROOT_RE = re.compile(r'/tmp/r76s-v111-lab\.[A-Za-z0-9]+\Z')
STATES = {f'{n:03b}' for n in range(8)}
MAX_FILE_BYTES = 4 * 1024 * 1024


class Blocked(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
    try:
        try:
            os.fsync(fd)
        except OSError as exc:
            if exc.errno not in (errno.EINVAL, errno.EBADF, errno.EISDIR):
                raise
            # Some macOS filesystems do not support directory fsync.
    finally:
        os.close(fd)


def secure_path(path, root, *, file=False):
    """Reject symlinks, hardlinked files, and paths escaping the lab."""
    if not path.is_relative_to(root):
        raise Blocked('PATH_OUTSIDE_LAB')
    cur = root
    for comp in path.relative_to(root).parts:
        cur = cur / comp
        try:
            s = cur.lstat()
        except FileNotFoundError:
            raise Blocked('MISSING_LAB_FILE') from None
        if stat.S_ISLNK(s.st_mode):
            raise Blocked('SYMLINK_BLOCKED')
        if cur == path and file:
            if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
                raise Blocked('NONREGULAR_OR_HARDLINKED_FILE')
        elif not stat.S_ISDIR(s.st_mode):
            raise Blocked('PARENT_NOT_DIRECTORY')


def read(path, root):
    secure_path(path, root, file=True)
    if path.stat().st_size > MAX_FILE_BYTES:
        raise Blocked('FILE_TOO_LARGE')
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    fd = os.open(path, flags)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_size > MAX_FILE_BYTES:
            raise Blocked('INVALID_OPEN_FILE')
        data = os.read(fd, MAX_FILE_BYTES + 1)
        if len(data) > MAX_FILE_BYTES:
            raise Blocked('FILE_TOO_LARGE')
        return data, stat.S_IMODE(st.st_mode)
    finally:
        os.close(fd)


def replace(path, data, mode):
    """Write with same-directory rename and fsync; caller checks path ownership."""
    temp = None
    try:
        fd, name = tempfile.mkstemp(prefix='.dns-v111-', dir=path.parent)
        temp = Path(name)
        with os.fdopen(fd, 'wb') as out:
            os.fchmod(out.fileno(), mode)
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, path)
        fsync_dir(path.parent)
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)


def root_dir(arg):
    path = Path(arg)
    if not ROOT_RE.fullmatch(str(path)):
        raise Blocked('ONLY_TMP_LAB_PATHS_ALLOWED')
    if not path.exists() or path.is_symlink() or not path.is_dir():
        raise Blocked('LAB_MISSING_OR_UNSAFE')
    if path.stat().st_uid != os.getuid():
        raise Blocked('LAB_OWNER_MISMATCH')
    if path.stat().st_mode & 0o077:
        raise Blocked('LAB_MUST_BE_PRIVATE_0700')
    return path


def txn_dir(root):
    return root / '.dns-txn'


def manifest(root):
    p = txn_dir(root) / 'manifest.json'
    raw, _ = read(p, root)
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as e:
        raise Blocked('CORRUPT_MANIFEST') from e
    if data.get('schema') != 1 or data.get('to_state') not in STATES or data.get('status') not in ('PREPARED', 'COMMITTING', 'COMMITTED', 'ROLLED_BACK'):
        raise Blocked('INVALID_MANIFEST_STATE')
    if set(data.get('files', {})) != set(FILES):
        raise Blocked('INVALID_MANIFEST_FILES')
    for name in FILES:
        info = data['files'][name]
        if not isinstance(info, dict) or not all(k in info for k in ('original_sha', 'candidate_sha', 'original_mode')):
            raise Blocked('INVALID_MANIFEST_ENTRY')
    return data


def save(root, data):
    p = txn_dir(root) / 'manifest.json'
    replace(p, (json.dumps(data, sort_keys=True, separators=(',', ':')) + '\n').encode(), 0o600)


def validate_file_set(root, status, data):
    """Check all targets BEFORE changing any; unknown edits fail closed."""
    current = {}
    for name in FILES:
        current[name] = read(root / 'current' / name, root)
        h = digest(current[name][0])
        entry = data['files'][name]
        if status == 'original':
            if h != entry['original_sha']:
                raise Blocked('EXTERNAL_EDIT_BLOCKED')
        elif h not in (entry['original_sha'], entry['candidate_sha']):
            raise Blocked('EXTERNAL_EDIT_BLOCKED')
    return current


def prepare(root, state):
    if state not in STATES:
        raise Blocked('INVALID_TARGET_STATE')
    td = txn_dir(root)
    if td.exists() or td.is_symlink():
        raise Blocked('TRANSACTION_ALREADY_EXISTS')
    originals = {}
    candidates = {}
    for name in FILES:
        originals[name] = read(root / 'current' / name, root)
        candidates[name] = read(root / 'candidate' / name, root)
    td.mkdir(mode=0o700)
    snap = td / 'snapshot'
    snap.mkdir(mode=0o700)
    try:
        files = {}
        for name in FILES:
            before, mode = originals[name]
            candidate, _ = candidates[name]
            if len(before) == 0 or len(candidate) == 0:
                raise Blocked('EMPTY_CONFIG_BLOCKED')
            replace(snap / name, before, 0o600)
            files[name] = dict(original_sha=digest(before), candidate_sha=digest(candidate), original_mode=mode)
        data = dict(schema=1, to_state=state, status='PREPARED', files=files)
        save(root, data)
        fsync_dir(td)
    except BaseException:
        for p in snap.glob('*'):
            p.unlink()
        snap.rmdir()
        (td / 'manifest.json').unlink(missing_ok=True)
        td.rmdir()
        raise
    print('LAB_TRANSACTION=PREPARED')


def apply(root):
    data = manifest(root)
    if data['status'] != 'PREPARED':
        raise Blocked('ROLLBACK_REQUIRED_BEFORE_REAPPLY')
    validate_file_set(root, 'original', data)
    candidates = {}
    for name in FILES:
        candidates[name] = read(root / 'candidate' / name, root)[0]
        if digest(candidates[name]) != data['files'][name]['candidate_sha']:
            raise Blocked('CANDIDATE_CHANGED_BLOCKED')
    data['status'] = 'COMMITTING'
    save(root, data)
    for name in FILES:
        target = root / 'current' / name
        # Don't mask concurrent edits or symlink replacement.
        existing, mode = read(target, root)
        if digest(existing) != data['files'][name]['original_sha']:
            raise Blocked('CONCURRENT_MODIFICATION_ROLLBACK_REQUIRED')
        replace(target, candidates[name], mode)
    data['status'] = 'COMMITTED'
    save(root, data)
    print('LAB_TRANSACTION=COMMITTED')


def rollback(root):
    data = manifest(root)
    if data['status'] == 'ROLLED_BACK':
        print('LAB_TRANSACTION=ALREADY_ROLLED_BACK')
        return
    validate_file_set(root, 'original_or_candidate', data)
    snapshots = {}
    for name in FILES:
        saved, _ = read(txn_dir(root) / 'snapshot' / name, root)
        if digest(saved) != data['files'][name]['original_sha']:
            raise Blocked('SNAPSHOT_INTEGRITY_FAILED')
        snapshots[name] = saved
    for name in FILES:
        target = root / 'current' / name
        current, _ = read(target, root)
        if digest(current) != data['files'][name]['original_sha']:
            replace(target, snapshots[name], data['files'][name]['original_mode'])
    data['status'] = 'ROLLED_BACK'
    save(root, data)
    print('LAB_TRANSACTION=ROLLED_BACK')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('prepare', 'apply', 'rollback', 'status'))
    p.add_argument('lab_root')
    p.add_argument('target_state', nargs='?')
    args = p.parse_args()
    root = root_dir(args.lab_root)
    if args.action == 'prepare':
        if args.target_state is None:
            raise Blocked('TARGET_STATE_REQUIRED')
        prepare(root, args.target_state)
    else:
        if args.target_state is not None:
            raise Blocked('EXTRA_ARGUMENT_BLOCKED')
        if args.action == 'apply':
            apply(root)
        elif args.action == 'rollback':
            rollback(root)
        else:
            d = manifest(root)
            print('LAB_TRANSACTION=' + d['status'])
            print('TARGET_STATE=' + d['to_state'])
    print('ROUTER_CONFIG_CHANGES=NONE')
    print('SERVICE_ACTIONS=NONE')


if __name__ == '__main__':
    try:
        main()
    except (Blocked, OSError, ValueError) as exc:
        print('BLOCKED: ' + str(exc), file=sys.stderr)
        sys.exit(4)

#!/usr/bin/env python3
"""Recover the lost phpbb_users rows from the MyISAM index.

The 2016 backup's phpbb_users.MYD was destroyed, but the .MYI index
survived. A MyISAM index stores the key value, not just a pointer to
the row, so the username of every member is still there. The .MYI
header records 13,971 rows, and an index-only scan of the untouched
file returns all 13,971 names.

The .MYI holds one key segment per index:

  * the PRIMARY key, on user_id, with the record:
        [3 bytes: the user_id]
        [6 bytes: the pointer to the row in the .MYD]

  * the unique index on username_clean, with the record:
        [1 byte:  the name length]
        [N bytes: the name]
        [3 bytes: a hash prefix]
        [3 bytes: the offset of the row in the .MYD]

The two segments hold the same row offsets, so joining them on the
offset gives the name and the user_id of every member, including the
members whose rows were destroyed.

The PRIMARY records are found by their shape: a run of 9 byte records
whose 3 byte user_ids ascend. The username records are found by their
shape too: a name from the index scan, followed by a row offset.

The names come from an index-only scan of the untouched table, which
MariaDB can do even though the table is marked as crashed. The scan
is read only, and it does not repair the table, so the index is left
as it was found.

Usage:
    python3 recover-users-from-index.py <datadir> <output.tsv>

The output is a tab separated file of user_id and username.
"""
import os
import struct
import subprocess
import sys

PRIMARY_UID = 3
PRIMARY_POINTER = 6
NAME_HASH = 3
NAME_POINTER = 3
MAX_USER_ID = 20000
MAX_POINTER = 4_000_000
STRIDE = PRIMARY_UID + PRIMARY_POINTER

CONTAINER = os.environ.get("MARIADB_CONTAINER", "phpbb-recovery")
DB_NAME = os.environ.get("PHPBB_DB_NAME", "phpbb")


def scan_names(container, db_name):
    """Return the usernames from an index-only scan of the table.

    The scan reads the username_clean index, so it needs no rows from
    the damaged .MYD. The table must not be repaired first, because
    the repair rebuilds the index and throws the lost entries away.
    """
    result = subprocess.run(
        ["docker", "exec", container, "mariadb", "-uroot", "-N", "-e",
         f"SELECT username_clean FROM {db_name}.phpbb_users "
         "FORCE INDEX (username_clean);"],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"the index scan failed: {result.stderr.strip()}")
    return [line.encode("latin-1", "replace")
            for line in result.stdout.splitlines() if line]


def find_primary(myi):
    """Return {row offset: user_id} from the PRIMARY index.

    The PRIMARY records are the runs of 9 byte records whose 3 byte
    user_ids ascend. The row offset is the last 3 bytes of the
    6 byte pointer that follows the user_id.
    """
    found = {}
    n = len(myi)
    i = 0
    while i + STRIDE * 20 <= n:
        ids = []
        for j in range(20):
            pos = i + j * STRIDE
            ids.append(int.from_bytes(myi[pos:pos + PRIMARY_UID], "big"))
        if not all(1 <= v <= MAX_USER_ID for v in ids):
            i += 1
            continue
        if not all(a < b for a, b in zip(ids, ids[1:])):
            i += 1
            continue
        # A run. Walk it to the end.
        end = i + 20 * STRIDE
        while end + STRIDE <= n:
            value = int.from_bytes(myi[end:end + PRIMARY_UID], "big")
            previous = int.from_bytes(
                myi[end - STRIDE:end - STRIDE + PRIMARY_UID], "big")
            if not (previous < value <= MAX_USER_ID):
                break
            end += STRIDE
        pos = i
        while pos < end:
            user_id = int.from_bytes(myi[pos:pos + PRIMARY_UID], "big")
            offset = int.from_bytes(
                myi[pos + PRIMARY_UID + 3:pos + STRIDE], "big")
            if offset < MAX_POINTER:
                found.setdefault(offset, user_id)
            pos += STRIDE
        i = end
    return found


def find_name_offsets(myi, names):
    """Return [(row offset, name)] for every name in the index."""
    entries = []
    for name in names:
        needle = bytes([len(name)]) + name
        at = myi.find(needle)
        while at >= 0:
            pos = at + 1 + len(name) + NAME_HASH
            if pos + NAME_POINTER <= len(myi):
                offset = int.from_bytes(myi[pos:pos + NAME_POINTER], "big")
                if offset < MAX_POINTER:
                    entries.append((offset, name))
                    break
            at = myi.find(needle, at + 1)
    return entries


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    datadir = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "recovered-users.tsv"

    myi_path = os.path.join(datadir, "phpbb_users.MYI")
    myi = open(myi_path, "rb").read()
    print(f"MYI: {len(myi):,} bytes")

    names = scan_names(CONTAINER, DB_NAME)
    print(f"names from the index scan: {len(names):,}")

    primary = find_primary(myi)
    print(f"row offsets with a user_id: {len(primary):,}")

    entries = find_name_offsets(myi, names)
    print(f"names located in the index: {len(entries):,}")

    pairs = []
    for offset, name in entries:
        user_id = primary.get(offset)
        if user_id is not None:
            pairs.append((user_id, name))
    print(f"paired: {len(pairs):,}")

    with open(out, "w", encoding="utf-8") as f:
        for user_id, name in pairs:
            f.write(f"{user_id}\t{name.decode('latin-1')}\n")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

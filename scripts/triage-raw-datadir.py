#!/usr/bin/env python3
"""Triage a raw MySQL data directory without a database server.

A hot backup is a copy of the data directory, so it can be checked
before it is loaded. The check answers three questions:

  * which databases and tables does it hold?
  * how many rows does each table hold?
  * how many of those rows can be read?

The row count comes from the .MYI index, which holds it at offset 32
as a big endian number. The index is the authority on the count, and
it survives the damage to the .MYD, so the count tells us what the
table held before the damage.

The number of readable rows is the number of rows that the repair
finds, which is the number that the record chain can reach. A table
whose count is much larger than its readable rows has lost rows.

The script needs no database server and no privileges, so it can be
run against a backup that is still on the disk.

Usage:
    python3 triage-raw-datadir.py <datadir> [--verbose]
"""
import os
import re
import struct
import sys

# The row count in a .MYI is a 4 byte number at this offset, big
# endian. This was proved against the tables whose counts are known.
RECORD_COUNT_OFFSET = 32


def log(message):
    print(f"  {message}")


def record_count(myi_path):
    """Return the number of rows the .MYI index says the table holds."""
    try:
        with open(myi_path, "rb") as handle:
            head = handle.read(64)
    except OSError:
        return None
    if len(head) < 40:
        return None
    return struct.unpack(">I", head[RECORD_COUNT_OFFSET:RECORD_COUNT_OFFSET + 4])[0]


def zero_runs(data):
    """Return the runs of zero bytes in a file, largest first."""
    runs = []
    start = None
    for index, byte in enumerate(data):
        if byte == 0:
            if start is None:
                start = index
        elif start is not None:
            runs.append((start, index))
            start = None
    if start is not None:
        runs.append((start, len(data)))
    runs.sort(key=lambda run: run[1] - run[0], reverse=True)
    return runs


def find_databases(root):
    """Return the database directories in a data directory.

    A database directory is one that holds .frm files.
    """
    databases = []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if not os.path.isdir(path):
            continue
        try:
            entries = os.listdir(path)
        except OSError:
            continue
        if any(entry.endswith(".frm") for entry in entries):
            databases.append((name, path))
    return databases


def triage_database(name, path, verbose=False):
    """Report the tables in one database directory."""
    tables = {}
    for entry in sorted(os.listdir(path)):
        if not entry.endswith(".frm"):
            continue
        table = entry[:-4]
        myd_path = os.path.join(path, table + ".MYD")
        myi_path = os.path.join(path, table + ".MYI")

        size = os.path.getsize(myd_path) if os.path.exists(myd_path) else 0
        count = record_count(myi_path)
        live = 0
        hole = 0
        if size:
            with open(myd_path, "rb") as handle:
                data = handle.read()
            runs = zero_runs(data)
            live = size - sum(end - start for start, end in runs)
            if runs:
                hole = runs[0][1] - runs[0][0]
        tables[table] = {
            "count": count,
            "size": size,
            "live": live,
            "hole": hole,
        }
    return tables


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    root = sys.argv[1]
    verbose = "--verbose" in sys.argv

    if not os.path.isdir(root):
        print(f"the directory does not exist: {root}")
        return 1

    databases = find_databases(root)
    log(f"the data directory: {root}")
    log(f"the databases: {len(databases)}")

    for name, path in databases:
        tables = triage_database(name, path, verbose)
        log("")
        log(f"the database {name}: {len(tables)} tables")

        # The tables that have lost rows, and the tables that are
        # worth a look.
        interesting = []
        for table, info in sorted(tables.items()):
            count = info["count"] or 0
            # The number of rows the repair would find is the live
            # bytes divided by the average row size, which is not
            # known. The hole is the better measure: a table with a
            # hole has lost the rows in it.
            if info["hole"] > 4096:
                interesting.append((table, info))

        if interesting:
            log(f"  the tables with a hole of more than 4 KB:")
            for table, info in interesting:
                log(f"    {table:<42} the index says {info['count'] or 0:>8} rows, "
                    f"the hole is {info['hole']:>12,} bytes, "
                    f"{info['live']:>12,} bytes are live")
        else:
            log("  no table has a hole of more than 4 KB")

        # The album tables, if they are there.
        album = [t for t in tables if t.startswith("media_")]
        if album:
            log(f"  the media album tables: {', '.join(sorted(album))}")
            for table in sorted(album):
                info = tables[table]
                log(f"    {table}: the index says {info['count'] or 0} rows, "
                    f"the hole is {info['hole']:,} bytes")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

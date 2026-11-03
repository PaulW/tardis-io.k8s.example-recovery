#!/usr/bin/env python3
"""Recover the lost rows of phpbb_log and phpbb_privmsgs from the 2016 backup.

The 2016 backup's phpbb_log.MYD and phpbb_privmsgs.MYD each have one
contiguous hole of zero bytes. The rows inside the hole are gone from
the data file, but the rows on either side of it are intact.

The recovery closes the hole: the live tail of the file is moved up
to where the hole started, so the two live regions become one
contiguous file. `REPAIR TABLE ... USE_FRM EXTENDED` then rebuilds
the index from the rows, and MariaDB reads them out.

The rows are written with `SELECT ... INTO OUTFILE`, one file per
column, with every value hex encoded. A hex value has no newlines and
no tabs, so the files can be read back a line at a time. The text
fields of the log and the private messages hold newlines, so a plain
dump cannot be split on a separator.

The rows that the merged database already holds are left alone. The
recovery only adds what is missing, and the loader skips the rows
that are already there.

Usage:
    python3 recover-tables-from-data-file.py <datadir> <outdir> <table> [...]
"""

import json
import os
import shutil
import subprocess
import sys

CONTAINER = "phpbb-tables-recovery"
IMAGE = "mariadb:11.4"

# The smallest hole that is worth recovering. A hole of a few bytes
# is a record that was deleted, not a damaged region.
MINIMUM_HOLE = 4096


def log(message):
    print(f"  {message}")


def find_hole(data):
    """Return the (start, end) of the longest run of zero bytes."""
    best = (0, 0)
    start = None
    for index, byte in enumerate(data):
        if byte == 0:
            if start is None:
                start = index
        elif start is not None:
            if index - start > best[1] - best[0]:
                best = (start, index)
            start = None
    if start is not None and len(data) - start > best[1] - best[0]:
        best = (start, len(data))
    return best


def close_hole(data):
    """Return the data file with the hole removed.

    The live tail is moved up to where the hole started. The row
    offsets in the index no longer match, so the index has to be
    rebuilt. That is what the repair does.
    """
    start, end = find_hole(data)
    if end - start < MINIMUM_HOLE:
        return None

    log(f"the hole runs from {start:,} to {end:,} "
        f"({end - start:,} bytes)")

    return bytes(data[:start]) + data[end:]


def docker(*args, capture=True):
    """Run a docker command and return the output."""
    result = subprocess.run(
        ["docker", *args],
        capture_output=capture, text=True)
    if result.returncode != 0 and capture:
        raise SystemExit(
            f"the command failed: {' '.join(args)}\n{result.stderr.strip()}")
    return result


def wait_for_mariadb():
    """Wait for the scratch server to accept connections."""
    for _ in range(60):
        result = subprocess.run(
            ["docker", "exec", CONTAINER, "mariadb", "-uroot",
             "-e", "SELECT 1;"],
            capture_output=True, text=True)
        if result.returncode == 0:
            return True
        subprocess.run(["sleep", "2"])
    return False


def sql(statement):
    """Run a statement in the scratch server."""
    result = subprocess.run(
        ["docker", "exec", CONTAINER, "mariadb", "-uroot", "-e", statement],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"the statement failed: {result.stderr.strip()}")


def read_columns(table):
    """Return the columns of the recovered table, in order."""
    result = subprocess.run(
        ["docker", "exec", CONTAINER, "mariadb", "-uroot", "-N", "-B", "-e",
         "SELECT column_name FROM information_schema.columns "
         f"WHERE table_schema = 'recovered' AND table_name = '{table}' "
         "ORDER BY ordinal_position;"],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"the query failed: {result.stderr.strip()}")
    return result.stdout.split()


def recover(table, datadir, out_dir):
    """Recover one table and write the rows to a JSON Lines file."""
    work = os.path.join(out_dir, f"work-{table}")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)

    data = open(os.path.join(datadir, f"{table}.MYD"), "rb").read()
    closed = close_hole(data)
    if closed is None:
        log(f"{table}: no hole worth recovering")
        return 0

    log(f"{table}: the closed file is {len(closed):,} bytes")

    # The table needs its .frm for the definition, and its .MYI for
    # the repair to work from. The .MYI's row offsets no longer match
    # the closed file, so the repair rebuilds the index from the rows.
    shutil.copy(os.path.join(datadir, f"{table}.frm"),
                os.path.join(work, f"{table}.frm"))
    shutil.copy(os.path.join(datadir, f"{table}.MYI"),
                os.path.join(work, f"{table}.MYI"))
    with open(os.path.join(work, f"{table}.MYD"), "wb") as handle:
        handle.write(closed)
    for name in os.listdir(work):
        os.chmod(os.path.join(work, name), 0o666)

    # The scratch server reads the closed file and repairs it.
    docker("rm", "-f", CONTAINER)
    docker("run", "-d", "--name", CONTAINER,
           "-e", "MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1",
           "-v", f"{work}:/var/lib/mysql/recovered", IMAGE)
    if not wait_for_mariadb():
        raise SystemExit("the scratch MariaDB did not start")

    try:
        sql(f"REPAIR TABLE recovered.{table} USE_FRM EXTENDED;")
        count = subprocess.run(
            ["docker", "exec", CONTAINER, "mariadb", "-uroot", "-N", "-B",
             "-e", f"SELECT COUNT(*) FROM recovered.{table};"],
            capture_output=True, text=True).stdout.strip()
        log(f"{table}: {count} rows recovered")

        columns = read_columns(table)
        log(f"{table}: the columns are {', '.join(columns)}")

        # Each column is written to its own file, with every value hex
        # encoded. A hex value has no newlines and no tabs, so the
        # files can be read back a line at a time. The text fields of
        # the log and the private messages hold newlines, so a plain
        # dump cannot be split on a separator.
        #
        # The columns are read from the table itself, because the
        # 2016 backup and the 3.3.19 schema do not have the same
        # columns. The phpbb_log table gained its post_id column in
        # 3.1.
        for index, column in enumerate(columns):
            target = f"/tmp/{table}-{index}.hex"
            sql(f"SELECT HEX(CAST({column} AS CHAR)) FROM recovered.{table} "
                f"ORDER BY {columns[0]} INTO OUTFILE '{target}';")
            docker("cp", f"{CONTAINER}:{target}",
                   os.path.join(work, f"{index:02d}.hex"))
            docker("exec", CONTAINER, "rm", "-f", target)

        # The columns are joined back into rows.
        column_files = []
        for index in range(len(columns)):
            path = os.path.join(work, f"{index:02d}.hex")
            with open(path, encoding="utf-8") as handle:
                column_files.append([line.strip() for line in handle])

        row_count = len(column_files[0])
        rows = []
        for index in range(row_count):
            row = []
            for values in column_files:
                value = values[index]
                # A NULL column comes back as the word NULL, and an
                # empty string comes back as nothing.
                if not value or value == "NULL":
                    row.append("")
                    continue
                row.append(bytes.fromhex(value).decode("utf-8", "replace"))
            rows.append(row)

        with open(os.path.join(out_dir, f"{table}.jsonl"), "w",
                  encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        log(f"{table}: {len(rows):,} rows written")
    finally:
        docker("rm", "-f", CONTAINER)

    return int(count or 0)


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 1

    datadir, out_dir = sys.argv[1], sys.argv[2]
    tables = sys.argv[3:]

    os.makedirs(out_dir, exist_ok=True)

    for table in tables:
        recover(table, datadir, out_dir)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

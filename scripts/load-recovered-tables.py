#!/usr/bin/env python3
"""Load the rows recovered from the 2016 data files into the forum database.

The recovery script writes the rows to a JSON Lines file. This script
loads them into the live database, skipping the rows that are already
there.

The rows are inserted one batch at a time, with the values escaped for
a MySQL string literal. The table is in strict mode, so the session
mode is relaxed for the insert. The strict mode is not a problem for
the columns that are recovered, because every one of them has a
default.

Usage:
    python3 load-recovered-tables.py <jsonl-dir> <db-name>
"""

import json
import os
import subprocess
import sys

CONTAINER = os.environ.get("MARIADB_CONTAINER", "phpbb-mariadb")
ROOT_PASS = os.environ.get("MARIADB_ROOT_PASSWORD", "root_secret_password")

# The tables to load, with the column that identifies a row and the
# columns to copy.
TABLES = {
    "phpbb_log": ("log_id", [
        "log_id", "log_type", "user_id", "forum_id", "topic_id",
        "reportee_id", "log_ip", "log_time",
        "log_operation", "log_data",
    ]),
    "phpbb_privmsgs": ("msg_id", [
        "msg_id", "root_level", "author_id", "icon_id", "author_ip",
        "message_time", "enable_bbcode", "enable_smilies",
        "enable_magic_url", "enable_sig", "message_subject",
        "message_text", "message_edit_reason", "message_edit_user",
        "message_attachment", "bbcode_bitfield", "bbcode_uid",
        "message_edit_time", "message_edit_count", "to_address",
        "bcc_address", "message_reported",
    ]),
}

# The rows are inserted in batches of this size.
BATCH = 200


def log(message):
    print(f"  {message}")


def query(sql, database=None):
    """Run a query and return the output."""
    command = ["docker", "exec", CONTAINER, "mariadb", "-uroot",
               f"-p{ROOT_PASS}", "-N", "-B"]
    if database:
        command.append(database)
    command += ["-e", sql]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"the query failed: {result.stderr.strip()}")
    return result.stdout


def escape(value):
    """Escape a value for a MySQL string literal."""
    return (value
            .replace("\\", "\\\\")
            .replace("'", "\\'")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\x00", "\\0")
            .replace("\t", "\\t")
            .replace("\x1a", "\\Z"))


def read_rows(path):
    """Read the JSON Lines file and return the rows."""
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    return rows


def load(table, path, db_name):
    """Load one table. Returns the number of rows inserted."""
    key, columns = TABLES[table]

    rows = read_rows(path)
    print(f"  {table}: {len(rows):,} rows read")

    # The 2016 backup and the 3.3.19 schema do not have the same
    # columns. The phpbb_log table gained its post_id column in 3.1.
    # The rows are matched to the live table by position, and a column
    # that the live table does not have is dropped.
    live = query(
        f"SELECT column_name FROM information_schema.columns "
        f"WHERE table_schema = '{db_name}' AND table_name = '{table}' "
        f"ORDER BY ordinal_position;", db_name).split()
    log(f"  {table}: the live columns are {', '.join(live)}")

    pairs = []
    for column in columns:
        if column in live:
            pairs.append((columns.index(column), column))
    dropped = [column for column in columns if column not in live]
    if dropped:
        print(f"  {table}: dropping the columns the live table does not "
              f"have: {', '.join(dropped)}")

    column_list = ", ".join(column for _, column in pairs)

    existing = set(query(
        f"SELECT {key} FROM {db_name}.{table};", db_name).split())

    todo = [row for row in rows if str(row[0]) not in existing]
    print(f"  {table}: {len(todo):,} rows to insert "
          f"({len(rows) - len(todo):,} already there)")

    inserted = 0
    for start in range(0, len(todo), BATCH):
        batch = todo[start:start + BATCH]
        values = []
        for row in batch:
            values.append("(" + ", ".join(
                f"'{escape(str(row[index]))}'" for index, _ in pairs) + ")")
        sql = (f"SET SESSION sql_mode='';\n"
               f"INSERT INTO {db_name}.{table} ({column_list}) VALUES "
               + ", ".join(values) + ";")
        query(sql, db_name)
        inserted += len(batch)

    print(f"  {table}: {inserted:,} rows inserted")
    return inserted


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    jsonl_dir, db_name = sys.argv[1], sys.argv[2]

    for table in TABLES:
        path = os.path.join(jsonl_dir, f"{table}.jsonl")
        if not os.path.exists(path):
            print(f"  {table}: {path} not found, skipping")
            continue
        load(table, path, db_name)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

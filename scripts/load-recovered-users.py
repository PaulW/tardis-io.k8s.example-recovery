#!/usr/bin/env python3
"""Load the users recovered from the phpbb_users index.

The recovered rows hold the username and the user_id, which are real.
Everything else about a user is unknown, so the other columns get
placeholder values. The rows are marked so that they are not confused
with the users whose rows survived.

The INSERT is built from the live table schema, so the column list and
the values always match.

Usage:
    python3 load-recovered-users.py <recovered.tsv> [database]
"""
import os
import subprocess
import sys

CONTAINER = os.environ.get("MARIADB_CONTAINER", "phpbb-mariadb")
ROOT_PASS = os.environ.get("MARIADB_ROOT_PASSWORD", "root_secret_password")
DB_NAME = os.environ.get("PHPBB_DB_NAME", "phpbb")

INT_TYPES = ("int", "tinyint", "smallint", "mediumint", "bigint")
DECIMAL_TYPES = ("decimal", "float", "double")


def db(query):
    """Run a query against the local MariaDB and return the rows."""
    result = subprocess.run(
        ["docker", "exec", CONTAINER, "mariadb", "-uroot",
         "-p" + ROOT_PASS, "-N", "-e", query],
        capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
    return [line for line in result.stdout.splitlines() if line]


def quote(value):
    """Quote a value for SQL."""
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def read_schema():
    """Read the phpbb_users column definitions."""
    columns = []
    for line in db(
            "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT "
            f"FROM information_schema.COLUMNS "
            f"WHERE TABLE_SCHEMA='{DB_NAME}' AND TABLE_NAME='phpbb_users' "
            "ORDER BY ORDINAL_POSITION;"):
        parts = line.split("\t")
        if len(parts) >= 4:
            columns.append({
                "name": parts[0],
                "type": parts[1],
                "nullable": parts[2],
                "default": parts[3],
            })
    return columns


def default_for(column):
    """The value to use for a column we know nothing about."""
    default = column["default"]

    # information_schema reports the default of a text column as the
    # SQL literal, so the default of a column that holds a single
    # character comes back as the three characters 't', with the
    # quotes included. It has to be unwrapped before it is used, or
    # the column ends up holding a literal "'t" and phpBB cannot
    # read it.
    #
    # The empty default comes back as the two characters of a pair of
    # apostrophes, which is unwrapped the same way.
    if len(default) >= 2 and default[0] == "'" and default[-1] == "'":
        default = default[1:-1].replace("''", "'")

    if default not in ("", "NULL"):
        if default.upper() == "NULL":
            return "NULL"
        if column["type"].lower().startswith(INT_TYPES):
            return default
        return quote(default)
    if column["nullable"] == "YES":
        return "NULL"
    if column["type"].lower().startswith(INT_TYPES):
        return "0"
    if column["type"].lower().startswith(DECIMAL_TYPES):
        return "0"
    # An empty string. It must be written as '' and not as the two
    # characters of a pair of apostrophes, or the column holds a
    # literal "''" and phpBB cannot read it.
    return "''"


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    source = sys.argv[1]

    recovered = []
    for line in open(source, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 2:
            continue
        try:
            user_id = int(parts[0])
        except ValueError:
            continue
        if parts[1]:
            recovered.append((user_id, parts[1]))

    columns = read_schema()
    if not columns:
        print("could not read the phpbb_users schema")
        return 1
    column_names = ", ".join(f"`{c['name']}`" for c in columns)

    # The users that are already in the table are not touched.
    existing = set()
    for line in db(f"SELECT user_id FROM {DB_NAME}.phpbb_users;"):
        if line.strip().isdigit():
            existing.add(int(line.strip()))

    # A name that is already in the table belongs to a member who has
    # already been recovered, so it is skipped. The index sometimes
    # gives the same member a different user_id, and the name is the
    # reliable key.
    taken_names = set()
    for line in db(f"SELECT username_clean FROM {DB_NAME}.phpbb_users;"):
        if line.strip():
            taken_names.add(line.strip().lower())

    # A user_id can only be used once.
    taken = set(existing)
    to_add = []
    skipped = 0
    for user_id, username in recovered:
        clean = username.lower()
        if clean in taken_names:
            skipped += 1
            continue
        if user_id in taken:
            skipped += 1
            continue
        taken.add(user_id)
        taken_names.add(clean)
        to_add.append((user_id, username))

    print(f"recovered pairs      : {len(recovered):,}")
    print(f"already in the table : {len(existing):,}")
    print(f"skipped              : {skipped:,}")
    print(f"rows to add          : {len(to_add):,}")
    if not to_add:
        print("nothing to add")
        return 0

    values = []
    for user_id, username in to_add:
        row = []
        for column in columns:
            name = column["name"]
            if name == "user_id":
                row.append(str(user_id))
            elif name == "username":
                row.append(quote(username))
            elif name == "username_clean":
                row.append(quote(username.lower()))
            elif name == "user_type":
                # A normal member. USER_NORMAL is 0. The value 2 is
                # USER_IGNORE, which phpBB uses for a bot, so a
                # member written with it is left out of the member
                # list.
                row.append("0")
            elif name == "group_id":
                # The registered members group.
                row.append("2")
            else:
                row.append(default_for(column))
        values.append(f"  ({', '.join(row)})")

    # The rows are inserted in batches, so one bad row does not lose
    # the whole recovery.
    batch_size = 500
    inserted = 0
    for start in range(0, len(values), batch_size):
        batch = values[start:start + batch_size]
        # The table is in strict mode, so every column must have a
        # value. The mode is relaxed for the insert, so a column that
        # the schema marks as NOT NULL without a default takes the
        # placeholder value.
        sql = ("SET SESSION sql_mode='';\n"
               f"INSERT INTO {DB_NAME}.phpbb_users ({column_names}) VALUES\n"
               + ",\n".join(batch) + ";")
        result = subprocess.run(
            ["docker", "exec", "-i", CONTAINER, "mariadb", "-uroot",
             "-p" + ROOT_PASS, DB_NAME],
            input=sql, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"  a batch failed: {result.stderr.strip()[:200]}")
            continue
        inserted += len(batch)
    print(f"rows inserted: {inserted:,}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Name the members whose user row was destroyed and whose name is lost.

There are 1,266 members on the board who are called "Former member N".
Their id is real, because the content refers to it, but their name is
not known. The index recovery only reads the username_clean index, and
it did not hold a name for them.

The name can still be in the forum's own caches, which store the name
and the id of the poster next to each other:

  * phpbb_topics holds the id and the name of the creator of a topic
    and of the last poster
  * phpbb_forums holds the id and the name of the last poster
  * phpbb_posts holds the id and the name of the author
  * phpbb_moderator_cache holds the id and the name of a moderator

The snapshots taken before the repair overwrote those names hold the
2016 values, and the 2013 database holds the 2013 values. Both are
read.

The snapshots are plain SQL dumps. Their INSERT statements name no
columns, so the column order comes from the CREATE TABLE that each
dump holds. The dump is the authority on the order.

A name is only used when it is safe:
  * the id must be a member whose name is not known
  * the name must not be the placeholder name
  * the name must not already be used by another member
  * when the sources disagree, the name is not used

Usage:
    python3 recover-lost-member-names.py [database] [--dry-run]
"""
import os
import re
import subprocess
import sys

CONTAINER = os.environ.get("MARIADB_CONTAINER", "phpbb-mariadb")
ROOT_PASS = os.environ.get("MARIADB_ROOT_PASSWORD", "root_secret_password")
DB_NAME = os.environ.get("PHPBB_DB_NAME", "phpbb")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SNAPSHOTS = os.path.join(REPO, "backup_recover/snapshots")
SOURCE_DB = os.environ.get("PHPBB_SOURCE_DB", "phpbb_2013")

# The tables that hold a name next to an id, and the id column and
# the name column of each.
SOURCES = {
    "phpbb_topics": [
        ("topic_poster", "topic_first_poster_name"),
        ("topic_last_poster_id", "topic_last_poster_name"),
    ],
    "phpbb_forums": [
        ("forum_last_poster_id", "forum_last_poster_name"),
    ],
    "phpbb_posts": [
        ("poster_id", "post_username"),
    ],
    "phpbb_moderator_cache": [
        ("user_id", "username"),
    ],
}

# The snapshots that are read, oldest first. The oldest one holds the
# 2016 values before the repair overwrote them.
SNAPSHOT_ORDER = [
    "phpbb-pre-migration.sql",
    "phpbb-pre-topic-drop.sql",
    "phpbb-final-merged-v2.sql",
]


def log(message):
    print(f"  {message}")


def db(query):
    """Run a query and return the rows."""
    result = subprocess.run(
        ["docker", "exec", CONTAINER, "mariadb", "-uroot",
         "-p" + ROOT_PASS, "-N", "-B", "-e", query],
        capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
        return []
    return [line.split("\t") for line in result.stdout.splitlines() if line]


def split_rows(body):
    """Split the body of an INSERT into its rows.

    A row is a bracketed list of values. The values hold text, and the
    text can hold brackets, so a plain pattern would cut a row short.
    The split therefore keeps track of the quoted strings.
    """
    rows = []
    depth = 0
    in_string = False
    escaped = False
    current = []
    for char in body:
        if escaped:
            current.append(char)
            escaped = False
            continue
        if char == "\\":
            current.append(char)
            escaped = True
            continue
        if char == "'":
            in_string = not in_string
            current.append(char)
            continue
        if in_string:
            current.append(char)
            continue
        if char == "(":
            depth += 1
            if depth == 1:
                current = []
                continue
        elif char == ")":
            depth -= 1
            if depth == 0:
                rows.append("".join(current))
                current = []
                continue
        current.append(char)
    return rows


def split_values(text):
    """Split a row of SQL values, honouring the quoted strings."""
    values = []
    current = []
    in_string = False
    escaped = False
    for char in text:
        if escaped:
            current.append(char)
            escaped = False
            continue
        if char == "\\":
            current.append(char)
            escaped = True
            continue
        if char == "'":
            in_string = not in_string
            current.append(char)
            continue
        if char == "," and not in_string:
            values.append("".join(current).strip())
            current = []
            continue
        current.append(char)
    if in_string:
        return None
    values.append("".join(current).strip())
    out = []
    for value in values:
        if len(value) >= 2 and value.startswith("'") and value.endswith("'"):
            value = value[1:-1]
        out.append(value.replace("''", "'"))
    return out


def create_table_columns(text, table):
    """Return the column names of a table, in the order of the dump."""
    match = re.search(
        r"CREATE TABLE `" + re.escape(table) + r"` \((.*?)\n\) ENGINE",
        text, re.S)
    if not match:
        return []
    columns = []
    for line in match.group(1).split("\n"):
        line = line.strip()
        if not line.startswith("`"):
            continue
        columns.append(line.split("`")[1])
    return columns


def pairs_from_snapshot(path):
    """Return {(id, name)} pairs found in a snapshot file."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()

    found = set()
    for table, pairs in SOURCES.items():
        names = create_table_columns(text, table)
        if not names:
            continue
        positions = []
        for id_col, name_col in pairs:
            if id_col in names and name_col in names:
                positions.append((names.index(id_col), names.index(name_col)))
        if not positions:
            continue

        pattern = re.compile(
            r"INSERT INTO `" + table + r"`(?:\s*\([^)]*\))?\s*VALUES\s*(.*?);\n",
            re.S)
        for match in pattern.finditer(text):
            for row in split_rows(match.group(1)):
                values = split_values(row)
                if values is None or len(values) != len(names):
                    continue
                for id_at, name_at in positions:
                    raw_id = values[id_at]
                    name = values[name_at]
                    if not raw_id.isdigit() or not name:
                        continue
                    found.add((int(raw_id), name))
    return found


def table_columns(table, database):
    """Return the column names of a table, in order."""
    rows = db("SELECT COLUMN_NAME FROM information_schema.COLUMNS "
              f"WHERE TABLE_SCHEMA='{database}' AND TABLE_NAME='{table}' "
              "ORDER BY ORDINAL_POSITION;")
    return [row[0] for row in rows]


def main():
    if len(sys.argv) < 2 or sys.argv[1].startswith("--"):
        print(__doc__)
        return 1
    database = sys.argv[1]
    dry_run = "--dry-run" in sys.argv

    # The members, and the ones whose name is not known.
    members = {}
    for user_id, username in db(
            f"SELECT user_id, username FROM {database}.phpbb_users;"):
        try:
            members[int(user_id)] = username
        except ValueError:
            continue
    lost = {uid for uid, name in members.items()
            if name == f"Former member {uid}"}
    log(f"the members: {len(members)}")
    log(f"the members whose name is not known: {len(lost)}")

    # The names that are already in use, so a name is not given to the
    # wrong member.
    taken = {}
    for user_id, username in members.items():
        if user_id not in lost:
            taken.setdefault(username.lower(), set()).add(user_id)
    log(f"the names already in use: {len(taken)}")

    candidates = {}

    def add(uid, name, source):
        if uid not in lost or not name:
            return
        if name.lower() == f"former member {uid}":
            return
        candidates.setdefault(uid, {}).setdefault(name, set()).add(source)

    # The 2013 database. Its tables hold the name next to the id.
    for table, pairs in SOURCES.items():
        names = table_columns(table, SOURCE_DB)
        if not names:
            continue
        positions = []
        for id_col, name_col in pairs:
            if id_col in names and name_col in names:
                positions.append((names.index(id_col), names.index(name_col)))
        if not positions:
            continue
        select = []
        for id_at, name_at in positions:
            select.append(names[id_at])
            select.append(names[name_at])
        rows = db(f"SELECT {', '.join(select)} FROM {SOURCE_DB}.{table};")
        for row in rows:
            for index in range(0, len(row) - 1, 2):
                try:
                    uid = int(row[index])
                except ValueError:
                    continue
                add(uid, row[index + 1], f"2013 {table}")
    log("  the 2013 database has been read")

    # The snapshots, which hold the 2016 values.
    for filename in SNAPSHOT_ORDER:
        path = os.path.join(SNAPSHOTS, filename)
        if not os.path.exists(path):
            continue
        pairs = pairs_from_snapshot(path)
        if not pairs:
            continue
        for uid, name in pairs:
            add(uid, name, filename)
        log(f"  {filename}: {len(pairs):,} name and id pairs")

    # The names that every source agrees on, and that are not in use.
    accepted = {}
    rejected = 0
    for uid in sorted(lost):
        options = candidates.get(uid, {})
        if not options:
            continue
        if len(options) > 1:
            rejected += 1
            continue
        name = next(iter(options))
        owners = taken.get(name.lower(), set())
        if owners and uid not in owners:
            rejected += 1
            continue
        accepted[uid] = name

    log(f"the members that can be named: {len(accepted)}")
    log(f"the members left unnamed because the sources disagree: {rejected}")

    if not dry_run and accepted:
        for uid, name in accepted.items():
            escaped = name.replace("'", "''")
            db(f"UPDATE {database}.phpbb_users SET username='{escaped}', "
               f"username_clean=LOWER('{escaped}') WHERE user_id={uid};")
        log(f"  the names written: {len(accepted)}")

        # The posts, the topics and the forums hold the name of the
        # poster, so the board can show a post without a join. The
        # names are taken from the member rows, so a member that has
        # just been named is no longer "Former member N" on the posts
        # it wrote.
        db(f"UPDATE {database}.phpbb_posts p "
           f"JOIN {database}.phpbb_users u ON u.user_id = p.poster_id "
           f"SET p.post_username = u.username "
           f"WHERE p.post_username <> u.username AND u.username <> '';")
        db(f"UPDATE {database}.phpbb_topics t "
           f"JOIN {database}.phpbb_posts p ON p.post_id = t.topic_first_post_id "
           f"SET t.topic_first_poster_name = p.post_username "
           f"WHERE t.topic_first_poster_name <> p.post_username;")
        db(f"UPDATE {database}.phpbb_topics t "
           f"JOIN {database}.phpbb_posts p ON p.post_id = t.topic_last_post_id "
           f"SET t.topic_last_poster_name = p.post_username "
           f"WHERE t.topic_last_poster_name <> p.post_username;")
        db(f"UPDATE {database}.phpbb_forums f "
           f"JOIN {database}.phpbb_posts p ON p.post_id = f.forum_last_post_id "
           f"SET f.forum_last_poster_name = p.post_username "
           f"WHERE f.forum_last_poster_name <> p.post_username;")
        log("  the poster names have been refreshed")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

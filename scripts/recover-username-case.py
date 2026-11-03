#!/usr/bin/env python3
"""Restore the original case of the member names.

The index recovery read the names from the username_clean index, and
that column holds the lowercase name by definition in phpBB. So the
members whose user row was destroyed have a lowercase name, and the
original case has to come from somewhere else.

The forum's own caches hold the name as it was written, so they hold
the original case:

  * phpbb_topics holds the name of the creator of a topic and the
    name of the last poster
  * phpbb_forums holds the name of the last poster of a forum
  * phpbb_moderator_cache holds the name of every moderator
  * phpbb_posts holds the name of the author of a post

The repair step overwrites the topic, forum and post names with the
member rows, so the live tables no longer hold the original case.
The snapshots taken before the repair still do, and so does the 2013
database.

A name is only used when it matches the member's current name,
ignoring the case. That way a member is never renamed to a different
member's name.

Usage:
    python3 recover-username-case.py [database] [--dry-run]
"""
import os
import re
import subprocess
import sys

CONTAINER = os.environ.get("MARIADB_CONTAINER", "phpbb-mariadb")
ROOT_PASS = os.environ.get("MARIADB_ROOT_PASSWORD", "root_secret_password")
DB_NAME = os.environ.get("PHPBB_DB_NAME", "phpbb")
SOURCE_DB = os.environ.get("PHPBB_SOURCE_DB", "phpbb_2013")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The snapshots that hold the names the repair step overwrote. The
# newest is first, so its names win.
SNAPSHOTS = [
    "backup_recover/snapshots/phpbb-pre-migration.sql",
    "backup_recover/snapshots/phpbb-pre-topic-drop.sql",
    "backup_recover/snapshots/phpbb-final-merged-v2.sql",
]

SCHEMA_FILE = "backup_recover/recovered/phpbb_schema.sql"

# The name columns of the tables that hold a poster name, and the
# column that holds the id of the member it belongs to.
TABLES = {
    "phpbb_posts": [("poster_id", "post_username")],
    "phpbb_topics": [("topic_poster", "topic_first_poster_name"),
                     ("topic_last_poster_id", "topic_last_poster_name")],
    "phpbb_forums": [("forum_last_poster_id", "forum_last_poster_name")],
    "phpbb_moderator_cache": [("user_id", "username")],
}


def log(message):
    print("  " + message)


def db(query, database=None):
    """Run a query and return the rows."""
    if database:
        query = "USE %s; %s" % (database, query)
    result = subprocess.run(
        ["docker", "exec", CONTAINER, "mariadb", "-uroot",
         "-p" + ROOT_PASS, "-N", "-e", query],
        capture_output=True, text=True)
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line]


def split_fields(row):
    """Split a SQL row into its fields, honouring the quotes."""
    fields = []
    current = ""
    in_string = False
    for char in row:
        if char == "'":
            in_string = not in_string
            current += char
        elif char == "," and not in_string:
            fields.append(current.strip())
            current = ""
        else:
            current += char
    fields.append(current.strip())
    return fields


def table_columns(table):
    """The columns of a table, in the order the 2016 schema has them."""
    schema = open(os.path.join(REPO_ROOT, SCHEMA_FILE),
                   encoding="utf-8", errors="replace").read()
    pattern = "CREATE TABLE `" + table + "` \\((.*?)\\n\\) ENGINE"
    match = re.search(pattern, schema, re.S)
    if not match:
        return []
    return re.findall(r"^\s*`(\w+)`", match.group(1), re.M)


def read_snapshot(path, table, pairs, into):
    """Read the names of one table out of a snapshot."""
    full = os.path.join(REPO_ROOT, path)
    if not os.path.exists(full):
        return 0

    columns = table_columns(table)
    if not columns:
        return 0

    try:
        indexes = [(columns.index(uid), columns.index(name))
                   for uid, name in pairs]
    except ValueError:
        return 0

    data = open(full, encoding="utf-8", errors="replace").read()
    match = re.search(r"INSERT INTO `" + table + r"` VALUES(.*?);\n", data, re.S)
    if not match:
        return 0

    found = 0
    for row in re.findall(r"\((.*?)\)(?:,|\s*$)", match.group(1), re.S):
        fields = split_fields(row)
        if len(fields) != len(columns):
            continue
        for uid_index, name_index in indexes:
            name = fields[name_index].strip("'")
            if not name:
                continue
            uid = fields[uid_index]
            if uid not in into or (into[uid] == into[uid].lower()
                                   and name != name.lower()):
                into[uid] = name
                found += 1
    return found


def main():
    global DB_NAME
    dry_run = "--dry-run" in sys.argv
    arguments = [a for a in sys.argv[1:] if not a.startswith("--")]
    if arguments:
        DB_NAME = arguments[0]

    names = {}

    # the snapshots, the newest first
    for path in SNAPSHOTS:
        for table, pairs in TABLES.items():
            read_snapshot(path, table, pairs, names)
    log("the names in the snapshots: %d" % len(names))

    # the 2013 database
    for table, pairs in TABLES.items():
        for uid_column, name_column in pairs:
            for row in db("SELECT %s, %s FROM %s WHERE %s <> '';"
                          % (uid_column, name_column, table, name_column),
                          SOURCE_DB):
                parts = row.split("\t")
                if len(parts) < 2 or not parts[1]:
                    continue
                uid, name = parts[0], parts[1]
                if uid not in names or (names[uid] == names[uid].lower()
                                        and name != name.lower()):
                    names[uid] = name
    log("the names with the 2013 database: %d" % len(names))

    # the live board, which holds the names of the members whose
    # rows survived
    for table, pairs in TABLES.items():
        for uid_column, name_column in pairs:
            for row in db("SELECT %s, %s FROM %s WHERE %s <> '';"
                          % (uid_column, name_column, table, name_column)):
                parts = row.split("\t")
                if len(parts) < 2 or not parts[1]:
                    continue
                uid, name = parts[0], parts[1]
                if uid not in names or (names[uid] == names[uid].lower()
                                        and name != name.lower()):
                    names[uid] = name
    log("the names with the live board: %d" % len(names))

    # the members whose name is all lower case
    members = {}
    for row in db("SELECT user_id, username FROM %s.phpbb_users "
                  "WHERE user_type IN (0, 1) AND username <> '' "
                  "AND username = LOWER(username) "
                  "AND username NOT LIKE 'Former member %%';" % DB_NAME):
        parts = row.split("\t")
        if len(parts) >= 2:
            members[parts[0]] = parts[1]
    log("the members with a lower case name: %d" % len(members))

    recased = 0
    skipped = 0
    for uid, name in members.items():
        if uid not in names:
            continue
        original = names[uid]

        # the cached name must be the same name, ignoring the case
        if original.lower() != name.lower():
            skipped += 1
            continue
        if original == name:
            continue

        if not dry_run:
            db("UPDATE %s.phpbb_users SET username = '%s', username_clean = '%s' "
               "WHERE user_id = %s;"
               % (DB_NAME, original.replace("\\", "\\\\").replace("'", "\\'"),
                  original.lower().replace("\\", "\\\\").replace("'", "\\'"),
                  uid))
        recased += 1

    log("the member names given their original case: %d" % recased)
    log("the names that did not match, so were left alone: %d" % skipped)
    if dry_run:
        log("this was a dry run, nothing was changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

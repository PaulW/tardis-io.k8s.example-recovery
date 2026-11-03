#!/usr/bin/env python3
"""Find the 2016 topics that the board does not have.

The 2016 recovery holds 3,835 topics. The board holds the topics
that had a post to render, and the 1,162 that did not were dropped,
because a topic without a post cannot be opened.

This reads the recovered 2016 topics and reports the ones the board
does not have, with the forum they belong to, so that the decision
about them can be taken on the facts.

The 2016 topics are in a SQL dump whose INSERT statements name no
columns, so the column order comes from the CREATE TABLE in the
schema file.

Usage:
    python3 recover-dropped-topic-titles.py [--write <file>]
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUMP = os.path.join(REPO, "backup_recover/recovered/phpbb_data.sql")
SCHEMA = os.path.join(REPO, "backup_recover/recovered/phpbb_schema.sql")
CONTAINER = os.environ.get("MARIADB_CONTAINER", "phpbb-mariadb")
ROOT_PASS = os.environ.get("MARIADB_ROOT_PASSWORD", "root_secret_password")
DB_NAME = os.environ.get("PHPBB_DB_NAME", "phpbb")


def log(message):
    print(f"  {message}")


def db(query):
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

    A row is a bracketed list of values. The values hold text, and
    the text can hold brackets, so the split keeps track of the
    quoted strings.
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


def split_values(row):
    """Split a row of SQL values, honouring the quoted strings."""
    values = []
    current = []
    in_string = False
    escaped = False
    for char in row:
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
    values.append("".join(current).strip())
    out = []
    for value in values:
        if len(value) >= 2 and value.startswith("'") and value.endswith("'"):
            value = value[1:-1]
        out.append(value.replace("''", "'"))
    return out


def read_topics():
    """Return the 2016 topics, keyed by their topic id."""
    schema = open(SCHEMA, encoding="utf-8", errors="replace").read()
    columns = []
    match = re.search(r"CREATE TABLE `phpbb_topics` \((.*?)\n\) ENGINE",
                      schema, re.S)
    for line in match.group(1).split("\n"):
        line = line.strip()
        if line.startswith("`"):
            columns.append(line.split("`")[1])
    title_at = columns.index("topic_title")
    forum_at = columns.index("forum_id")
    poster_at = columns.index("topic_poster")
    time_at = columns.index("topic_time")
    first_at = columns.index("topic_first_post_id")

    text = open(DUMP, encoding="utf-8", errors="replace").read()
    topics = {}
    pattern = re.compile(
        r"INSERT INTO `phpbb_topics`(?:\s*\([^)]*\))?\s*VALUES\s*(.*?);\n",
        re.S)
    for match in pattern.finditer(text):
        for row in split_rows(match.group(1)):
            values = split_values(row)
            if len(values) != len(columns):
                continue
            try:
                topic_id = int(values[0])
            except ValueError:
                continue
            topics[topic_id] = {
                "topic_id": topic_id,
                "title": values[title_at],
                "forum_id": values[forum_at],
                "poster": values[poster_at],
                "time": values[time_at],
                "first_post_id": values[first_at],
            }
    return topics


def main():
    write = None
    if "--write" in sys.argv:
        write = sys.argv[sys.argv.index("--write") + 1]

    board = {}
    for topic_id, title in db(
            f"SELECT topic_id, topic_title FROM {DB_NAME}.phpbb_topics;"):
        board[int(topic_id)] = title
    log(f"the topics on the board: {len(board):,}")

    topics = read_topics()
    log(f"the 2016 topics: {len(topics):,}")

    missing = {tid: t for tid, t in topics.items() if tid not in board}
    log(f"the 2016 topics the board does not have: {len(missing):,}")

    forums = {int(row[0]): row[1] for row in db(
        f"SELECT forum_id, forum_name FROM {DB_NAME}.phpbb_forums;")}
    by_forum = {}
    for topic in missing.values():
        by_forum.setdefault(topic["forum_id"], []).append(topic)

    print()
    for forum_id in sorted(by_forum, key=lambda f: int(f)):
        rows = by_forum[forum_id]
        print("  %-40s %4d topics" % (forums.get(forum_id, forum_id),
                                       len(rows)))
        for topic in rows[:3]:
            print("      %6d | %s" % (topic["topic_id"], topic["title"][:60]))

    if write:
        with open(write, "w", encoding="utf-8") as handle:
            for topic in missing.values():
                handle.write(json.dumps(topic, ensure_ascii=False) + "\n")
        log(f"the topics written to {write}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

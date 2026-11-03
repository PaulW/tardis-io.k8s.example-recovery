#!/usr/bin/env python3
"""Put the 1,162 dropped topics back, as titles without posts.

The 2016 recovery held 1,162 topics that had no post. The 2016
damage took the posts out of them and left the topic rows, and the
repair dropped them, because a topic without a post cannot be opened
and was a dead link.

The titles of those topics are not lost. They are in the recovered
2016 topics, and they are worth keeping, because they are the record
of what the forum was about.

A topic without a post is still a dead link, so putting the rows
back into phpbb_topics would put the dead links back. The titles are
therefore written to a file, and to a table of their own, so that the
record survives without the forum showing a topic that cannot be
opened.

The table is phpbb_recovered_topic_titles. It is not a phpBB table,
so phpBB does not read it, and it does not affect the forum.

Usage:
    python3 restore-dropped-topic-titles.py [--dry-run]
"""
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTAINER = os.environ.get("MARIADB_CONTAINER", "phpbb-mariadb")
ROOT_PASS = os.environ.get("MARIADB_ROOT_PASSWORD", "root_secret_password")
DB_NAME = os.environ.get("PHPBB_DB_NAME", "phpbb")

# The table that holds the titles.
TABLE = "phpbb_recovered_topic_titles"

CREATE = f"""
CREATE TABLE IF NOT EXISTS {DB_NAME}.{TABLE} (
  topic_id MEDIUMINT(8) UNSIGNED NOT NULL,
  forum_id MEDIUMINT(8) UNSIGNED NOT NULL DEFAULT 0,
  topic_title VARCHAR(255) NOT NULL DEFAULT '',
  topic_poster MEDIUMINT(8) UNSIGNED NOT NULL DEFAULT 0,
  topic_time INT(11) UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (topic_id),
  KEY forum_id (forum_id)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;
"""


def log(message):
    print(f"  {message}")


def db(query, database=None):
    command = ["docker", "exec", CONTAINER, "mariadb", "-uroot",
               "-p" + ROOT_PASS, "-N", "-B"]
    if database:
        command.append(database)
    command += ["-e", query]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"the query failed: {result.stderr.strip()}")
    return [line.split("\t") for line in result.stdout.splitlines() if line]


def escape(value):
    return (value
            .replace("\\", "\\\\")
            .replace("'", "\\'")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\x00", "\\0")
            .replace("\t", "\\t"))


def read_dropped():
    """Return the 2016 topics the board does not have."""
    result = subprocess.run(
        ["python3", os.path.join(REPO, "scripts",
                                "recover-dropped-topic-titles.py"),
         "--write", "/tmp/dropped-topics.jsonl"],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"the recovery failed: {result.stderr.strip()}")
    rows = []
    with open("/tmp/dropped-topics.jsonl", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def main():
    dry_run = "--dry-run" in sys.argv

    rows = read_dropped()
    log(f"the dropped topics: {len(rows):,}")

    if dry_run:
        for row in rows[:10]:
            log(f"  {row['topic_id']} | {row['forum_id']} | {row['title'][:60]}")
        return 0

    db(CREATE)
    log("the table is ready")

    # The rows that are already there are left alone.
    existing = set(int(row[0]) for row in db(f"SELECT topic_id FROM {DB_NAME}.{TABLE};"))
    todo = [row for row in rows if row["topic_id"] not in existing]
    log(f"the rows to insert: {len(todo):,}")

    BATCH = 200
    for start in range(0, len(todo), BATCH):
        batch = todo[start:start + BATCH]
        values = []
        for row in batch:
            values.append("(%d, %d, '%s', %d, %d)" % (
                row["topic_id"],
                int(row["forum_id"] or 0),
                escape(row["title"][:255]),
                int(row["poster"] or 0) if str(row["poster"]).isdigit() else 0,
                int(row["time"] or 0) if str(row["time"]).isdigit() else 0,
            ))
        db(f"INSERT INTO {DB_NAME}.{TABLE} (topic_id, forum_id, topic_title, "
           f"topic_poster, topic_time) VALUES " + ", ".join(values) + ";")

    total = int(db(f"SELECT COUNT(*) FROM {DB_NAME}.{TABLE};")[0][0])
    log(f"the rows in the table: {total:,}")

    # The titles are also written out, so that the record is in the
    # backup and not only in the database.
    out = os.path.join(REPO, "backup_recover/dropped-topic-titles.tsv")
    with open(out, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write("%d\t%s\t%s\n" % (
                row["topic_id"], row["forum_id"], row["title"]))
    log(f"the titles written to {out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Create the member rows that the content refers to but that do not exist.

The 2013 dump was truncated during the phpbb_sessions_keys table, so it
has no phpbb_users table at all. The 1,224 members who wrote the 2013
posts and the 397 who wrote the private messages are therefore
missing, and phpBB cannot render a post whose author is missing.

The names are not recoverable, so each member gets a name that says
so. The row is a placeholder: it holds the id and nothing else, in the
same way as the members that were recovered from the index.

The rows are the users that the content refers to, so the ids are
taken from the content. The rest of the columns take the board
defaults.

The INSERT is built from the live table's own schema, so it cannot
drift from the table.

Usage:
    python3 create-missing-users.py [db-name]
"""

import os
import subprocess
import sys

CONTAINER = os.environ.get("MARIADB_CONTAINER", "phpbb-mariadb")
ROOT_PASS = os.environ.get("MARIADB_ROOT_PASSWORD", "root_secret_password")
DB_NAME = os.environ.get("PHPBB_DB_NAME", "phpbb")

# The columns that are set to something other than the default. The
# rest are left to the table.
VALUES = {
    "user_type": "0",
    "group_id": "3",
    "user_permissions": "''",
    "user_perm_from": "0",
    "user_ip": "''",
    "username": "CONCAT('Former member ', user_id)",
    "username_clean": "CONCAT('former member ', user_id)",
    "user_password": "''",
    "user_email": "''",
    "user_birthday": "''",
    "user_lastvisit": "0",
    "user_last_active": "0",
    "user_lastmark": "0",
    "user_lastpost_time": "0",
    "user_lastpage": "''",
    "user_warnings": "0",
    "user_posts": "(SELECT COUNT(*) FROM phpbb_posts q WHERE q.poster_id = user_id)",
    "user_lang": "'en'",
    "user_timezone": "'Europe/London'",
    # The format has to have the lower case 'd' in it, for the day of
    # the month. 'D M Y H:i' has no day of the month at all, and the
    # member sees 'Thu Nov 2004 16:32' instead of 'Thu Nov 24 2004
    # 16:32'. The format is the one the members whose row survived
    # use, and it has both the day of the week and the day of the
    # month.
    "user_dateformat": "'D M d Y H:i'",
    "user_style": "1",
    "user_rank": "0",
    "user_colour": "'000000'",
    "user_new_privmsg": "0",
    "user_unread_privmsg": "0",
    "user_last_privmsg": "0",
    "user_message_rules": "''",
    "user_full_folder": "0",
    "user_emailtime": "0",
    "user_topic_show_days": "0",
    "user_topic_sortby_type": "'t'",
    "user_topic_sortby_dir": "'a'",
    "user_post_show_days": "0",
    "user_post_sortby_type": "'t'",
    "user_post_sortby_dir": "'a'",
    "user_notify": "0",
    "user_notify_pm": "0",
    "user_notify_type": "0",
    "user_allow_pm": "1",
    "user_allow_viewonline": "1",
    "user_allow_viewemail": "1",
    "user_allow_massemail": "0",
    "user_options": "0",
    "user_avatar": "''",
    "user_avatar_type": "'0'",
    "user_avatar_width": "0",
    "user_avatar_height": "0",
    "user_sig": "''",
    "user_sig_bbcode_uid": "''",
    "user_sig_bbcode_bitfield": "''",
    "user_jabber": "''",
    "user_actkey": "''",
    "user_actkey_expiration": "0",
    "reset_token": "''",
    "reset_token_expiration": "0",
    "user_newpasswd": "''",
    "user_form_salt": "''",
    "user_new": "0",
    "user_reminded": "0",
    "user_reminded_time": "0",
}


def db(sql, database=None):
    """Run a query and return the output lines."""
    command = ["docker", "exec", CONTAINER, "mariadb", "-uroot",
               f"-p{ROOT_PASS}", "-N", "-B"]
    if database:
        command.append(database)
    command += ["-e", sql]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"the query failed: {result.stderr.strip()}")
    return [line for line in result.stdout.splitlines() if line]


def main():
    global DB_NAME
    if len(sys.argv) > 1:
        DB_NAME = sys.argv[1]

    # The columns of the live table, and their defaults.
    columns = {}
    for line in db(
            "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT "
            "FROM information_schema.COLUMNS "
            f"WHERE TABLE_SCHEMA='{DB_NAME}' AND TABLE_NAME='phpbb_users' "
            "ORDER BY ORDINAL_POSITION;", DB_NAME):
        name, column_type, nullable, default = line.split("\t")
        columns[name] = (column_type, nullable, default)

    def value_for(name):
        """The value to use for a column."""
        if name in VALUES:
            return VALUES[name]
        column_type, nullable, default = columns[name]

        # The default is the SQL literal, so it comes back with the
        # quotes included. The default of a one character column is
        # the three characters 't', and the default of an empty
        # column is the two characters of a pair of apostrophes. It
        # has to be unwrapped before it is used, or the column ends
        # up holding a literal apostrophe and phpBB cannot read it.
        if len(default) >= 2 and default[0] == "'" and default[-1] == "'":
            default = default[1:-1].replace("''", "'")

        if default not in ("", "NULL"):
            if default.upper() == "NULL":
                return "NULL"
            if column_type.lower().startswith(("int", "tinyint", "smallint",
                                               "mediumint", "bigint")):
                return default
            if default == "":
                return "''"
            return "'" + default.replace("\\", "\\\\").replace("'", "\\'") + "'"
        if nullable == "YES":
            return "NULL"
        if column_type.lower().startswith(("int", "tinyint", "smallint",
                                           "mediumint", "bigint")):
            return "0"
        if column_type.lower().startswith(("decimal", "float", "double")):
            return "0"
        return "''"

    # The members that the content refers to but that do not exist.
    missing = db(
        "SELECT DISTINCT p.poster_id FROM phpbb_posts p "
        "LEFT JOIN phpbb_users u ON u.user_id = p.poster_id "
        "WHERE u.user_id IS NULL AND p.poster_id > 1 "
        "UNION "
        "SELECT DISTINCT p.author_id FROM phpbb_privmsgs p "
        "LEFT JOIN phpbb_users u ON u.user_id = p.author_id "
        "WHERE u.user_id IS NULL AND p.author_id > 1;", DB_NAME)

    print(f"  the members that are missing: {len(missing):,}")
    if not missing:
        print("  nothing to do")
        return 0

    # The rows are inserted in batches, so the statement is not too big.
    batch = 200
    inserted = 0
    for start in range(0, len(missing), batch):
        group = missing[start:start + batch]
        values = []
        for user_id in group:
            fields = {"user_id": user_id,
                      "user_regdate": "(SELECT config_value FROM phpbb_config "
                                      "WHERE config_name = 'board_startdate')"}
            for name in columns:
                if name in fields:
                    continue
                fields[name] = value_for(name)
            names = ", ".join(f"`{name}`" for name in fields)
            vals = ", ".join(fields[name] for name in fields)
            values.append(f"({vals})")
        sql = (f"SET SESSION sql_mode='';\n"
               f"INSERT INTO {DB_NAME}.phpbb_users ({names}) VALUES "
               + ", ".join(values) + ";")
        db(sql, DB_NAME)
        inserted += len(group)

    print(f"  the members created: {inserted:,}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

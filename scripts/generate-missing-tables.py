#!/usr/bin/env python3
"""Generate CREATE TABLE statements for the tables missing from the
recovered forum database, using phpBB's own schema.

phpBB 3.3.19 ships its schema as install/schemas/schema.json, which
the installer reads to create every table. Eleven tables in the 2016
backup were too damaged to repair, so they are absent from the
recovery. This script recreates them from the shipped schema.

Two details the schema needs translating for:

  * A multi-column key is expressed as a LIST of column names, for
    example ["notification_type_id", "item_id"]. MySQL needs them as
    separate backticked names.

  * Some key columns are typed TEXT, which MySQL cannot index without
    a prefix length. phpBB's own installer maps those to varchar, so
    this script does the same.

Usage:
    python3 scripts/generate-missing-tables.py > missing-tables.sql
"""
import json
import subprocess
import sys

IMAGE = "phpbb-phpbb-installer:latest"
SCHEMA_PATH = "/var/www/html/install/schemas/schema.json"

# The tables that could not be recovered from the 2016 backup.
MISSING = [
    "phpbb_ext",
    "phpbb_migrations",
    "phpbb_notifications",
    "phpbb_oauth_accounts",
    "phpbb_oauth_tokens",
    "phpbb_config_text",
    "phpbb_autogroups_rules",
    "phpbb_autogroups_types",
    "phpbb_notification_types",
    "phpbb_user_notifications",
]

# phpBB's type names, and the MySQL type each maps to.
#
# ULINT is an unsigned long that phpBB stores in a BIGINT column.
# MTEXT and TEXT_UNI are MEDIUMTEXT and TEXT with a unique index, so
# they need a prefix length to be indexable.
TYPES = {
    "VCHAR": "varchar(255)",
    "CHAR": "char(255)",
    "BOOL": "tinyint(1)",
    "TEXT": "text",
    "MTEXT": "mediumtext",
    "TEXT_UNI": "text",
    "TIMESTAMP": "int(11)",
    "UINT:10": "int(10) unsigned",
    "UINT": "int(10) unsigned",
    "ULINT": "bigint(20) unsigned",
    "USINT": "smallint(5) unsigned",
    "INT": "int(11)",
    "TINYINT": "tinyint(3)",
}

# A TEXT or MEDIUMTEXT column cannot be indexed without a prefix
# length, so any such column that is part of a key becomes a
# varchar. This mirrors what phpBB's own installer does.
KEY_PREFIX_LENGTH = 191


def load_schema():
    result = subprocess.run(
        ["docker", "run", "--rm", "--entrypoint", "cat", IMAGE, SCHEMA_PATH],
        capture_output=True, text=True)
    if result.returncode != 0 or not result.stdout.strip():
        print(f"could not read {SCHEMA_PATH} from {IMAGE}", file=sys.stderr)
        print(result.stderr[:400], file=sys.stderr)
        raise SystemExit(1)
    return json.loads(result.stdout)


def mysql_type(ctype, extra):
    if ctype in TYPES:
        base = TYPES[ctype]
    elif ctype.startswith("VCHAR:"):
        base = f"varchar({ctype.split(':')[1]})"
    elif ctype.startswith("UINT:"):
        base = f"int({ctype.split(':')[1]}) unsigned"
    elif ctype.startswith("USINT:"):
        base = f"smallint({ctype.split(':')[1]}) unsigned"
    else:
        base = "text"
    if extra == "auto_increment":
        base += " NOT NULL AUTO_INCREMENT"
    return base


def key_columns(spec):
    """phpBB writes a multi-column key as a list of names."""
    if isinstance(spec, list):
        return [str(c) for c in spec]
    return [str(spec)]


def main():
    schema = load_schema()

    out = [
        "-- Tables that could not be recovered from the 2016 backup.",
        "-- Recreated from phpBB 3.3.19 install/schemas/schema.json.",
        "SET SESSION sql_mode='';",
        "",
    ]

    for table in MISSING:
        definition = schema.get(table)
        if definition is None:
            print(f"-- not in the 3.3.19 schema, skipped: {table}",
                  file=sys.stderr)
            continue

        # Work out which columns are part of a key, so a TEXT column
        # in a key can be mapped to a varchar.
        key_columns_used = set()
        primary = definition.get("PRIMARY_KEY")
        if primary:
            key_columns_used.update(key_columns(primary))
        for _name, keydef in definition.get("KEYS", {}).items():
            key_columns_used.update(key_columns(keydef[1]))

        columns = []
        for name, spec in definition.get("COLUMNS", {}).items():
            ctype, default, *rest = spec
            extra = rest[0] if rest else None
            if ctype in ("TEXT", "MTEXT", "TEXT_UNI") and name in key_columns_used:
                ctype = "VCHAR:255"
            line = f"  `{name}` {mysql_type(ctype, extra)}"
            if extra != "auto_increment":
                if default is None or default == "":
                    if ctype == "TEXT":
                        line += " NOT NULL"
                elif isinstance(default, str):
                    line += f" NOT NULL DEFAULT '{default}'"
                else:
                    line += f" NOT NULL DEFAULT {default}"
            columns.append(line)

        body = ",\n".join(columns)

        primary = definition.get("PRIMARY_KEY")
        if primary:
            cols = key_columns(primary)
            body += ",\n  PRIMARY KEY (" + ", ".join(f"`{c}`" for c in cols) + ")"

        for name, keydef in definition.get("KEYS", {}).items():
            kind = keydef[0]
            cols = key_columns(keydef[1])
            collist = ", ".join(f"`{c}`" for c in cols)
            if kind == "PRIMARY":
                body += f",\n  PRIMARY KEY ({collist})"
            elif kind == "UNIQUE":
                body += f",\n  UNIQUE KEY `{name}` ({collist})"
            elif kind == "INDEX":
                body += f",\n  KEY `{name}` ({collist})"

        out.append(f"CREATE TABLE IF NOT EXISTS `{table}` (\n{body}\n"
                   f") ENGINE=MyISAM DEFAULT CHARSET=utf8;")
        out.append("")

    print("\n".join(out))


if __name__ == "__main__":
    main()

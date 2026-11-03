# Recovering a phpBB forum from a broken backup

> **This is a companion to a blog post, not a maintained project.**
>
> It is the tool behind
> [Recovering a phpBB Forum From a Broken Backup](https://www.paulbramhall.uk/recovering-a-phpbb-forum-from-a-broken-backup/),
> published so that the scripts the post describes can be read in full
> and copied. The post explains what each one does and why it is the
> way it is.
>
> **It is not maintained.** There is no issue tracker, no support, no
> release cadence, and no backwards compatibility. These scripts were
> written once, for one board, and they will not be kept working for
> yours. Read them, take what you need, and expect to have to change
> them.
>
> **They are not a tool for recovering your forum.** They assume a
> phpBB 3.1.x board, a MySQL 5.x data directory, a MariaDB instance
> that will let you run `REPAIR TABLE`, and a working shell. If any of
> that is not true of your setup, they will not help you.
>
> **Everything has been genericised.** The forum's own name, its
> database names, its addresses and its administrator's name have been
> replaced with placeholders. The scripts are otherwise exactly as they
> ran, because a script that has been tidied up is a script that has
> not been tested.

## What this is for

A phpBB forum lives in two places: the web root, which holds the
code, the avatars and the media album, and the database, which holds
the content. When the hardware fails, you hope you have a backup of
both.

This is the set of scripts that came out of one such failure, where
the database backup turned out to be damaged in a way that needed
understanding before it could be used.

The post walks through what the damage was, how it was found, and what
each step of the recovery did. This repository is the tool it used.

## The scripts

### The pipeline

These are the steps, in the order the post gives them.

| The step | The script | What it does |
|---|---|---|
| 1 | `recover-forum-db.sh` | Repairs the 2016 raw data directory and dumps it to SQL |
| 2 | `generate-missing-tables.py` | Recreates the tables that could not be recovered |
| 3 | `load-recovered-db.sh` | Loads the recovered data into the local MariaDB |
| 4 | `merge-forum-data.sh` | Merges the 2013 dump into it, rebuilding the missing topics |
| 5 | `snapshot-recovered-db.sh` | Writes a checksummed snapshot of the result |
| 6 | `migrate-forum-schema.sh` | Migrates the schema from 3.1.9 to 3.3.19 |
| 7 | `repair-recovered-forum.sh` | Fixes the data that the migration cannot fix |
| 8 | `snapshot-recovered-db.sh` | Writes a snapshot of the migrated result |
| 9 | `export-for-deployment.sh` | Writes a deployment bundle for the cluster |

### The tools

| The script | What it does |
|---|---|
| `triage-raw-datadir.py` | Reads a raw MySQL data directory without a database server, and reports what it holds |
| `recover-tables-from-data-file.py` | Closes the hole in a damaged data file and recovers the rows past it |
| `recover-users-from-index.py` | Recovers member names from a MyISAM index, when the rows are gone |
| `recover-lost-member-names.py` | Recovers member names from the forum's own caches |
| `recover-username-case.py` | Recovers the original capitalisation of a member's name |
| `recover-avatars.py` | Puts the avatars back onto the members who lost their row |
| `recover-dropped-topic-titles.py` | Finds the titles of the topics that had no posts |
| `restore-dropped-topic-titles.py` | Puts those titles back into the board |
| `load-recovered-tables.py` | Loads the rows the recovery wrote out |
| `load-recovered-users.py` | Loads the members recovered from the index |
| `create-missing-users.py` | Creates the placeholder rows for the members the content refers to |
| `restore-missing-bot-accounts.php` | Restores the bot accounts that the board expects |
| `restore-staff-roles.php` | Restores the ranks, the colours and the moderator list |
| `fix-bot-accounts.php` | Points the bot rows at members that exist |
| `fix-member-date-format.php` | Fixes the date format the loader mangled |
| `apply-inferred-join-dates.php` | Sets the join dates that were inferred rather than recovered |
| `interpolate-remaining-join-dates.php` | Fills the remaining join dates by interpolation |
| `drop-empty-topics.php` | Drops the topics that have no posts |
| `rebuild-forum-tree.php` | Rebuilds the nested set the forum's tree depends on |
| `repair-acp-modules.php` | Repairs the administration panel's module tree |
| `write-restore-notes.sh` | Writes the notes that ship with a deployment bundle |
| `bring-to-parity.sql` | The SQL that brings the schema to the stock phpBB shape |

### The environment

The scripts read what they need from the environment. The ones that
matter are:

| The variable | What it is |
|---|---|
| `MARIADB_ROOT_PASSWORD` | The MariaDB root password. The default is the one from the published compose file |
| `PHPBB_DB_NAME` | The database name. The default is `phpbb` |
| `MARIADB_CONTAINER` | The container the recovery runs in |
| `FOUNDER_USERNAME` | The board's founder. The repair script makes this member the founder, because the recovered board has none |

The defaults for the passwords are the ones from the
[example forum repository](https://github.com/PaulW/tardis-io.k8s.example-forum),
so they are already public. Set your own.

## The parts that are worth reading first

If you are only going to read a few, read these.

**`triage-raw-datadir.py`** answers the question you should ask
before you trust a backup: what does it hold, and how much of it can
be read? It reads a MySQL data directory without loading it, so it
can be run against a candidate backup before you commit to it.

**`recover-users-from-index.py`** is the one that surprised me. A
MyISAM index stores the key value, not just a pointer to the row, so
a table whose data file was destroyed can still yield its data from
the index. The `username_clean` index holds the username of every
member who ever registered. The trick does not generalise: it works
for a table with an index whose key is something a human would
recognise, and not for one whose index holds only a number.

**`repair-recovered-forum.sh`** is the largest, and it is the step
that mattered most. It fixes the faults the schema migration cannot,
and each one is silent. A repair that does not happen is a forum
that looks fine and cannot be used.

## The other repository

The container image and the deployment for the same board are in
[the example forum repository](https://github.com/PaulW/tardis-io.k8s.example-forum),
along with the posts that describe them.

## Licence

The scripts are published so they can be read and copied. Use them
however you like.

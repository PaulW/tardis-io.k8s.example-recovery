#!/bin/bash
# =====================================================================
# Write the restore notes into a deployment bundle.
# =====================================================================
# The notes are part of the bundle, so that whoever loads it has the
# instructions next to the file.
#
# Usage:
#   ./scripts/write-restore-notes.sh <bundle-dir>
# =====================================================================
set -euo pipefail

BUNDLE="${1:?usage: write-restore-notes.sh <bundle-dir>}"
[ -d "${BUNDLE}" ] || { echo "ERROR: ${BUNDLE} is not a directory" >&2; exit 1; }

DB_NAME="phpbb"

cat > "${BUNDLE}/RESTORE.md" <<'EOF'
# Restoring the forum on the cluster

This bundle holds the recovered forum.example.com forum. It is the state the
forum was in when the bundle was made, so it is the point that a
later change is measured from.

## What is in the bundle

| The file | What it is |
|---|---|
| `phpbb.sql` | The database. One file. Load it over the top of a working forum and it replaces it. |
| `avatars/` | The member avatars. They are files, not rows, so they are copied separately. |
| `MANIFEST.txt` | The table row counts, the server settings and the checksums. |

The dump holds the password hash of every member. It is the only
copy of the accounts, so the bundle is a secret. Do not put it in
git, and do not send it anywhere that is not the cluster.

## The order to do it in

The forum must be running before the database is loaded, so that the
avatars can be copied in.

1. Deploy the forum image. The installer is **not** used, because
   the installer would create its own schema and its own admin
   account over the top of the recovered one.

2. Create the database, and the user the forum connects as.

   ```sql
   CREATE DATABASE phpbb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   CREATE USER 'phpbb'@'%' IDENTIFIED BY '<the password>';
   GRANT ALL PRIVILEGES ON phpbb.* TO 'phpbb'@'%';
   FLUSH PRIVILEGES;
   ```

3. Load the dump.

   ```sh
   mariadb -u root -p phpbb < phpbb.sql
   ```

   The dump has `DROP TABLE IF EXISTS` for every table, so it can be
   loaded over an existing database. It does not create the
   database, so step 2 has to be done first.

4. Copy the avatars into the forum. The path is the one phpBB
   expects, and the file names are the avatar salt, an underscore,
   the user id and the extension.

   ```sh
   cp avatars/* /var/www/html/images/avatars/upload/
   ```

   The files belong to the forum user, so the pod has to own them.

   ```sh
   chown -R 1000:1000 /var/www/html/images/avatars/upload/
   ```

5. Clear the phpBB cache. The config is cached on disk, and the
   cached copy still holds the settings from the recovery machine.

   ```sh
   rm -f /var/www/html/cache/production/data_*.php
   ```

6. Check it. The board index should show the member count, and the
   notice should be the first post in General Discussion.

   ```sh
   curl -s https://forum.example.com/index.php | grep -c "Total members"
   ```

## The server settings

The dump sets these, so the forum on the cluster builds the right
links and sets the right cookie. They are at the end of the dump,
after the table data, so they are the last word on the values.

| Setting | The value |
|---|---|
| `server_name` | `forum.example.com` |
| `server_port` | `443` |
| `server_protocol` | `https://` |
| `script_path` | `/` |
| `cookie_secure` | `1` |
| `cookie_domain` | empty |
| `force_server_vars` | `0` |

`cookie_domain` is empty on purpose. It was `.forum.example.com` in the
recovered database, which came out of the 2016 backup. A browser
throws away a cookie that is set for a domain it is not on, so the
session cookie was never kept, and nobody could log in.

`force_server_vars` is off for the same reason. It makes phpBB build
every URL from the settings above, rather than from the request, so
it has to be off for the request to be the source of truth.

## The forum is read only

Every forum is locked. A member cannot post and cannot reply. The
administrators and the moderators can, because they hold the
`m_lock` permission.

To open the forum up, unlock the forums and the topics.

```sql
UPDATE phpbb_forums SET forum_status = 0 WHERE forum_type = 1;
UPDATE phpbb_topics SET topic_status = 0;
```

## The mail

The board points at the SMTP server from the old setup, and that
name does not resolve. The cluster has a mail relay, so the
settings have to be changed for the cluster.

```sql
UPDATE phpbb_config SET config_value = 'mail.example.com' WHERE config_name = 'smtp_host';
UPDATE phpbb_config SET config_value = '587' WHERE config_name = 'smtp_port';
UPDATE phpbb_config SET config_value = 'PLAIN' WHERE config_name = 'smtp_auth_method';
UPDATE phpbb_config SET config_value = '' WHERE config_name = 'smtp_username';
UPDATE phpbb_config SET config_value = '' WHERE config_name = 'smtp_password';
```

The sender address has to be one the relay is allowed to send from,
so `board_email` has to be a domain the cluster has onboarded.

The password reset needs this, and so does anything else that sends
mail.
EOF

echo "wrote ${BUNDLE}/RESTORE.md"

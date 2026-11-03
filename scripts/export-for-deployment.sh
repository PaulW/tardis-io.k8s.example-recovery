#!/bin/bash
# =====================================================================
# Export the recovered forum, ready to push up to the cluster.
# =====================================================================
# The snapshot script in this folder takes a safety copy of the
# recovered database, so that a later experiment can be thrown away
# and retried. This script does something different. It writes a
# deployment bundle, which is the state the cluster needs to run the
# forum:
#
#   phpbb.sql   The database, ready to load.
#   avatars/            The member avatars, in the layout phpBB
#                       expects in images/avatars/upload.
#   MANIFEST.txt        What the bundle holds, and the checksums.
#   RESTORE.md          How to load it.
#
# The bundle is built for a clean install. The cluster gets a fresh
# MariaDB, the forum image is deployed, and the database is loaded
# over the top of it. The installer is not used, because the
# installer would create its own schema and its own admin user.
#
# The one thing the installer does that this bundle does not is set
# the server settings, and the bundle carries them. The settings in
# the recovered database point at the local stack, because that is
# where the recovery was done. They have to point at the cluster
# host when the bundle is loaded, so the export writes them for the
# deployment target, not for the recovery machine.
#
# Usage:
#   ./scripts/export-for-deployment.sh [--server-name <host>]
#                                      [--server-port <port>]
#                                      [--server-protocol <url>]
#                                      [--script-path <path>]
#                                      [--cookie-secure <true|false>]
#                                      [--label <name>]
#
# The defaults are the settings the production site needs. The host
# is forum.example.com, because that is the domain in the deployment values.
# =====================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/backup_recover/deploy"
CONTAINER="phpbb-mariadb"
DB_NAME="${PHPBB_DB_NAME:-phpbb}"
ROOT_PASS="${MARIADB_ROOT_PASSWORD:-root_secret_password}"

# The settings the cluster serves the forum on. These are the
# defaults, because they are the settings the production site needs.
SERVER_NAME="forum.example.com"
SERVER_PORT="443"
SERVER_PROTOCOL="https://"
SCRIPT_PATH="/"
COOKIE_SECURE="1"
LABEL="$(date +%Y%m%d-%H%M%S)"

log() { echo "[export] $*"; }
die() { echo "[export] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --server-name)    SERVER_NAME="$2";    shift 2 ;;
        --server-port)    SERVER_PORT="$2";    shift 2 ;;
        --server-protocol) SERVER_PROTOCOL="$2"; shift 2 ;;
        --script-path)    SCRIPT_PATH="$2";    shift 2 ;;
        --cookie-secure)  COOKIE_SECURE="$2";  shift 2 ;;
        --label)          LABEL="$2";          shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

# cookie_secure is stored as a number, and a non-empty string is
# truthy in PHP. The word "false" would turn the secure flag on.
case "${COOKIE_SECURE}" in
    true|1)  COOKIE_SECURE=1 ;;
    false|0) COOKIE_SECURE=0 ;;
    *) die "--cookie-secure must be 'true' or 'false', got '${COOKIE_SECURE}'" ;;
esac

docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$" \
    || die "MariaDB container ${CONTAINER} is not running"

BUNDLE="${OUT_DIR}/${DB_NAME}-${LABEL}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/avatars"

# --- 1. The database -----------------------------------------------------
# The dump is taken with the settings the cluster needs, so the
# forum does not have to be patched after it is loaded.
#
# The password hash of every member is in the dump. It is the only
# copy of the accounts, so the bundle has to be treated as a secret.
log "dumping ${DB_NAME} to ${BUNDLE}/${DB_NAME}.sql"
docker exec "${CONTAINER}" mariadb-dump -uroot "-p${ROOT_PASS}" \
    --single-transaction --quick --routines --events --triggers \
    --default-character-set=utf8mb4 \
    "${DB_NAME}" > "${BUNDLE}/${DB_NAME}.sql"

# The server settings are written after the dump, so the forum on
# the cluster generates the right links and sets the right cookie.
# They are written in the dump itself, rather than as a second
# statement to run later, so that the bundle is one file to load.
#
# The table prefix is read from the forum container, because it is
# configurable and the statements have to use the same one. The
# container has BusyBox grep, which has no -P option, so the line is
# cut with sed instead.
TABLE_PREFIX=$(docker exec phpbb-app sh -c \
    "sed -n \"s/.*table_prefix = getenv('PHPBB_TABLE_PREFIX') ?: '\\([^']*\\)'.*/\\1/p\" /var/www/html/config.php" \
    2>/dev/null | head -1)
[ -n "${TABLE_PREFIX}" ] || TABLE_PREFIX="phpbb_"
log "the table prefix: ${TABLE_PREFIX}"

log "writing the server settings for ${SERVER_PROTOCOL}//${SERVER_NAME}:${SERVER_PORT}"
{
    echo "UPDATE ${TABLE_PREFIX}config SET config_value = '${SERVER_NAME}' WHERE config_name = 'server_name';"
    echo "UPDATE ${TABLE_PREFIX}config SET config_value = '${SERVER_PORT}' WHERE config_name = 'server_port';"
    echo "UPDATE ${TABLE_PREFIX}config SET config_value = '${SERVER_PROTOCOL}' WHERE config_name = 'server_protocol';"
    echo "UPDATE ${TABLE_PREFIX}config SET config_value = '${SCRIPT_PATH}' WHERE config_name = 'script_path';"
    echo "UPDATE ${TABLE_PREFIX}config SET config_value = '${COOKIE_SECURE}' WHERE config_name = 'cookie_secure';"
    echo "UPDATE ${TABLE_PREFIX}config SET config_value = '' WHERE config_name = 'cookie_domain';"
    echo "UPDATE ${TABLE_PREFIX}config SET config_value = '0' WHERE config_name = 'force_server_vars';"
} > "${BUNDLE}/server-settings.sql"

# The settings go at the end of the dump, after the table data, so
# they are the last word on the values.
cat "${BUNDLE}/server-settings.sql" >> "${BUNDLE}/${DB_NAME}.sql"
rm -f "${BUNDLE}/server-settings.sql"

# The dump has to be worth something. An empty one means the dump
# failed, and a bundle with an empty dump in it would be loaded over
# a working forum and destroy it.
DUMP_BYTES=$(wc -c < "${BUNDLE}/${DB_NAME}.sql" | tr -d ' ')
[ "${DUMP_BYTES}" -gt 1000000 ] \
    || die "the dump is only ${DUMP_BYTES} bytes, so it is not usable"

# --- 2. The avatars ------------------------------------------------------
# The avatars are not in the database. They are files, and they are
# in a Docker volume, so they have to be copied out by hand.
#
# The layout is the one phpBB expects. The file name is the avatar
# salt, then an underscore, then the user id, then the extension.
AVATAR_DIR="${REPO_ROOT}/backup_recover/avatars"
if [ -d "${AVATAR_DIR}" ]; then
    log "copying the avatars from ${AVATAR_DIR}"
    cp "${AVATAR_DIR}"/* "${BUNDLE}/avatars/" 2>/dev/null || true
fi

AVATARS=$(find "${BUNDLE}/avatars" -type f | wc -l | tr -d ' ')
log "  the avatar files: ${AVATARS}"

# --- 3. The manifest -----------------------------------------------------
SIZE=$(wc -c < "${BUNDLE}/${DB_NAME}.sql" | tr -d ' ')
log "the dump is ${SIZE} bytes"

{
    echo "forum.example.com forum deployment bundle"
    echo
    echo "The label            : ${LABEL}"
    echo "The database         : ${DB_NAME}"
    echo "The dump             : ${DB_NAME}.sql (${SIZE} bytes)"
    echo "The avatar files     : ${AVATARS}"
    echo
    echo "The server settings in the dump:"
    echo "  server_name        : ${SERVER_NAME}"
    echo "  server_port        : ${SERVER_PORT}"
    echo "  server_protocol    : ${SERVER_PROTOCOL}"
    echo "  script_path        : ${SCRIPT_PATH}"
    echo "  cookie_secure      : ${COOKIE_SECURE}"
    echo "  cookie_domain      : (empty)"
    echo "  force_server_vars  : 0"
    echo
    echo "The table row counts:"
    docker exec "${CONTAINER}" mariadb -uroot "-p${ROOT_PASS}" -N -e \
        "SELECT table_name, table_rows FROM information_schema.tables
         WHERE table_schema='${DB_NAME}' ORDER BY table_name;" 2>/dev/null \
        | sed 's/^/  /'
    echo
    echo "The file checksums:"
    (cd "${BUNDLE}" && find . -type f ! -name MANIFEST.txt -print0 \
        | sort -z | xargs -0 shasum -a 256 | sed 's/^/  /')
} > "${BUNDLE}/MANIFEST.txt"
log "wrote ${BUNDLE}/MANIFEST.txt"

# --- 4. The restore notes ------------------------------------------------
# The notes are part of the bundle, so that whoever loads it has the
# instructions next to the file.
log "writing the restore notes"
"${REPO_ROOT}/scripts/write-restore-notes.sh" "${BUNDLE}" >/dev/null

log "done"

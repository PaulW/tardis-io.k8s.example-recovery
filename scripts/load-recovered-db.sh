#!/bin/bash
# =====================================================================
# Load the recovered 2016/2017 forum data into the local MariaDB.
# =====================================================================
# The recovered data uses the 2016 schema (phpBB 3.1.9/3.2.2). The
# forum container runs phpBB 3.3.19, which needs the schema migrated
# forward. phpBB's own updater does that: it detects an older version
# in the phpbb_config table and runs the migration.
#
# This script:
#   1. Loads the recovered schema and data into a database.
#   2. Reports what was loaded.
#
# The phpBB version in the recovered database must match the forum
# code, or phpBB will refuse to run. Run the installer image's update
# command against the database to migrate the schema forward.
#
# Usage:
#   ./scripts/load-recovered-db.sh [database-name]
#
# Default database name: phpbb
# =====================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECOVERED="${REPO_ROOT}/backup_recover/recovered"
DB_NAME="${1:-phpbb}"
CONTAINER="phpbb-mariadb"
# The local MariaDB is created by docker compose with these
# credentials. Read them from the compose environment so the script
# works with a customised .env.
DB_PASS="${PHPBB_DB_PASS:-phpbb_secret_password}"
ROOT_PASS="${MARIADB_ROOT_PASSWORD:-root_secret_password}"
# The phpbb user has rights on the phpbb database only, so the root
# user is used for the load.
MYSQL=(mariadb -uroot "-p${ROOT_PASS}")

log() { echo "[load] $*"; }
die() { echo "[load] ERROR: $*" >&2; exit 1; }

[ -f "${RECOVERED}/phpbb_schema.sql" ] \
    || die "no recovered schema found. Run scripts/recover-forum-db.sh first."

# --- Make sure MariaDB is up -------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    log "starting MariaDB"
    (cd "${REPO_ROOT}/app-code/phpbb" && docker compose up -d mariadb) >/dev/null
    for i in $(seq 1 60); do
        if [ "$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null)" = "healthy" ]; then
            break
        fi
        sleep 2
    done
fi
[ "$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null)" = "healthy" ] \
    || die "MariaDB did not become healthy"
log "MariaDB is healthy"

# --- Load ---------------------------------------------------------------
log "dropping any previous ${DB_NAME} database"
docker exec "${CONTAINER}" "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" >/dev/null

log "creating ${DB_NAME}"
docker exec "${CONTAINER}" "${MYSQL[@]}" -e "CREATE DATABASE \`${DB_NAME}\` DEFAULT CHARACTER SET latin1 COLLATE latin1_swedish_ci;" >/dev/null

log "loading the recovered schema"
docker exec -i "${CONTAINER}" "${MYSQL[@]}" "${DB_NAME}" \
    < "${RECOVERED}/phpbb_schema.sql"

log "loading the recovered data"
docker exec -i "${CONTAINER}" "${MYSQL[@]}" "${DB_NAME}" \
    < "${RECOVERED}/phpbb_data.sql"

# --- Report -------------------------------------------------------------
log ""
log "loaded row counts:"
for t in phpbb_users phpbb_topics phpbb_posts phpbb_forums phpbb_config phpbb_privmsgs; do
    n=$(docker exec "${CONTAINER}" "${MYSQL[@]}" -N -e \
        "SELECT COUNT(*) FROM \`${DB_NAME}\`.\`${t}\`;" 2>/dev/null | head -1)
    printf '  %-24s %s\n' "${t}" "${n}"
done

log ""
log "forum version in the recovered data:"
docker exec "${CONTAINER}" "${MYSQL[@]}" -N -e \
    "SELECT CONCAT('  phpBB ', config_value) FROM \`${DB_NAME}\`.phpbb_config WHERE config_name='version';" 2>/dev/null

log ""
log "loaded into database '${DB_NAME}' on the local MariaDB"
log "to use it, set PHPBB_DB_NAME=${DB_NAME} in app-code/phpbb/.env"

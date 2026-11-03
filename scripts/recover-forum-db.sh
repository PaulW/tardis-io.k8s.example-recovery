#!/bin/bash
# =====================================================================
# Recover the 2016/2017 Corsa B UK forum database.
# =====================================================================
# Reads the raw MySQL data directory from
# `backup_recover/phpbb_database_backup.tar.gz`, repairs the
# damaged MyISAM tables, and exports the result as a SQL dump plus a
# schema-only dump.
#
# The archive is a hot copy of a live MySQL 5.x data directory, taken
# between May 2016 and December 2017. Most of the tables have a
# damaged or zero-filled index, so they need
#
#     REPAIR TABLE <table> USE_FRM EXTENDED
#
# which rebuilds the index from the .frm definition and the .MYD data.
#
# REPAIR TABLE rewrites the files in place, so this script always
# works on a copy. The archive is never modified.
#
# Usage:
#   ./scripts/recover-forum-db.sh [output-dir]
#
# Default output directory: ./backup_recover/recovered
# =====================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${REPO_ROOT}/backup_recover"
# The archive to recover. Any tarball containing a MySQL data
# directory works, so an older backup can be recovered with the same
# script.
ARCHIVE="${BACKUP_DIR}/${PHPBB_DB_ARCHIVE:-phpbb_database_backup.tar.gz}"
# The database directory name inside the archive. It is normally the
# same as the database name.
DB_NAME="${PHPBB_DB_NAME:-phpbb}"
OUT_DIR="${1:-${BACKUP_DIR}/recovered}"
WORK_DIR="${OUT_DIR}/work"
CONTAINER="phpbb-recovery"

log() { echo "[recover] $*"; }
die() { echo "[recover] ERROR: $*" >&2; exit 1; }

# --- Preflight ----------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker is required"
[ -f "${ARCHIVE}" ] || die "archive not found: ${ARCHIVE}"

mkdir -p "${OUT_DIR}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# --- Extract ------------------------------------------------------------
log "extracting the data directory"
tar -xzf "${ARCHIVE}" -C "${WORK_DIR}"

# The archive stores the full backup path. Find the database directory.
# Find the data directory. It holds the .frm files, so look for the
# directory that contains them rather than guessing the name.
DB_SRC="$(find "${WORK_DIR}" -type d -name '*.frm' -print -quit 2>/dev/null | xargs -r dirname | head -1)"
if [ -z "${DB_SRC}" ]; then
    # Fall back to a name match.
    DB_SRC="$(find "${WORK_DIR}" -type d -name "${DB_NAME}" | head -1)"
fi
[ -n "${DB_SRC}" ] || die "could not find a MySQL data directory in the archive"

log "database directory: ${DB_SRC}"
chmod -R u+w "${DB_SRC}"

TABLE_COUNT=$(find "${DB_SRC}" -name '*.frm' | wc -l | tr -d ' ')
log "found ${TABLE_COUNT} tables"

# --- Preserve the original indexes --------------------------------------
# REPAIR TABLE rewrites the .MYI files. For most tables that is a
# loss, because the original index held data that the .MYD file no
# longer has.
#
# A MyISAM index stores the key value, not just a pointer to the row.
# The phpbb_users index is on username_clean, so it still holds the
# username of every row, even for the rows whose data was destroyed.
# The same is true of phpbb_log and phpbb_privmsgs.
#
# Copy the original .MYI files out before the repair, so the lost
# members can be recovered afterwards.
PRISTINE_INDEX_DIR="${OUT_DIR}/pristine-index"
mkdir -p "${PRISTINE_INDEX_DIR}"
while read -r myi; do
    [ -z "${myi}" ] && continue
    cp "${myi}" "${PRISTINE_INDEX_DIR}/" 2>/dev/null || true
done <<< "$(find "${DB_SRC}" -name '*.MYI')"
log "preserved $(find "${PRISTINE_INDEX_DIR}" -name '*.MYI' | wc -l | tr -d ' ') original index files"

# The phpbb_users data file is needed as well. The index holds the
# offset of each row in it, so the two are read together.
mkdir -p "${PRISTINE_INDEX_DIR}"
cp "${DB_SRC}/phpbb_users.MYD" "${PRISTINE_INDEX_DIR}/" 2>/dev/null || true

# The data files of phpbb_log and phpbb_privmsgs are needed too. The
# repair truncates them at the point where the hole starts, so the
# rows on either side of the hole are lost. The recovery closes the
# hole and reads the rows back.
for table in phpbb_log phpbb_privmsgs; do
    cp "${DB_SRC}/${table}.MYD" "${PRISTINE_INDEX_DIR}/" 2>/dev/null || true
done

# --- Repair -------------------------------------------------------------
# MariaDB 11.4 reads the MySQL 5.x .frm files directly, so no older
# MySQL server is needed. The tables must be owned by the mysql user
# for the server to open them.
log "starting MariaDB"
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" \
    -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
    -v "${DB_SRC}":/var/lib/mysql/"${DB_NAME}" \
    mariadb:11.4 >/dev/null

# Wait for the server to accept connections.
for i in $(seq 1 60); do
    if docker exec "${CONTAINER}" mariadb -uroot -e "SELECT 1;" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
docker exec "${CONTAINER}" mariadb -uroot -e "SELECT 1;" >/dev/null 2>&1 \
    || die "MariaDB did not start"
log "MariaDB is up"

# --- Recover the users from the index ---------------------------------
# The phpbb_users data file was destroyed, but the index survived. A
# MyISAM index stores the key value, not just a pointer to the row, so
# the username of every member is still there, together with the
# user_id in the PRIMARY index.
#
# This has to run before the repair, because the repair rebuilds the
# index from the data file and throws the lost entries away.
log "recovering the users from the index"
MARIADB_CONTAINER="${CONTAINER}" PHPBB_DB_NAME="${DB_NAME}" \
    python3 "${REPO_ROOT}/scripts/recover-users-from-index.py" \
        "${PRISTINE_INDEX_DIR}" "${OUT_DIR}/recovered-users.tsv" 2>&1 \
    | sed 's/^/  /' || true

log "repairing tables"
REPAIRED=0
FAILED=0
while read -r table; do
    [ -z "${table}" ] && continue
    # USE_FRM rebuilds the table definition from the .frm file, which
    # is what the damaged tables need. EXTENDED rebuilds the index
    # from the data file.
    if docker exec "${CONTAINER}" mariadb -uroot -N -e \
        "REPAIR TABLE \`${DB_NAME}\`.\`${table}\` USE_FRM EXTENDED;" >/dev/null 2>&1; then
        REPAIRED=$((REPAIRED + 1))
    else
        FAILED=$((FAILED + 1))
        log "  could not repair: ${table}"
    fi
done <<< "$(docker exec "${CONTAINER}" mariadb -uroot -N -e \
    "SELECT table_name FROM information_schema.tables
     WHERE table_schema='${DB_NAME}' ORDER BY table_name;" 2>/dev/null)"

log "repaired ${REPAIRED} tables, ${FAILED} failed"

# --- Recover the tables with a hole in the data file --------------------
# The repair stops at the point where the hole starts, so the rows on
# either side of the hole are lost. The recovery closes the hole and
# reads the rows back. The result is written next to the dump, and the
# loader puts the rows that are missing into the database.
#
# This runs after the repair, because it needs the repaired index as
# well as the original data file.
log "recovering the rows that the repair lost"
RECOVERED_DIR="${OUT_DIR}/recovered-tables"
mkdir -p "${RECOVERED_DIR}"
python3 "${REPO_ROOT}/scripts/recover-tables-from-data-file.py" \
    "${PRISTINE_INDEX_DIR}" "${RECOVERED_DIR}" \
    phpbb_log phpbb_privmsgs 2>&1 | sed 's/^/  /' || true

# Some tables have a broken .frm and cannot be repaired. They are
# unusable, so drop them so the dump and the restored database are
# consistent.
log "checking for unusable tables"
UNUSABLE=""
while read -r table; do
    [ -z "${table}" ] && continue
    if ! docker exec "${CONTAINER}" mariadb -uroot -N -e \
        "SELECT COUNT(*) FROM \`${DB_NAME}\`.\`${table}\`;" >/dev/null 2>&1; then
        UNUSABLE="${UNUSABLE}${table}"$'\n'
    fi
done <<< "$(docker exec "${CONTAINER}" mariadb -uroot -N -e \
    "SELECT table_name FROM information_schema.tables
     WHERE table_schema='${DB_NAME}' ORDER BY table_name;" 2>/dev/null)"

if [ -n "${UNUSABLE}" ]; then
    log "dropping tables that cannot be read:"
    while read -r t; do
        [ -z "${t}" ] && continue
        log "  ${t}"
        docker exec "${CONTAINER}" mariadb -uroot -e \
            "DROP TABLE IF EXISTS \`${DB_NAME}\`.\`${t}\`;" >/dev/null 2>&1 || true
    done <<< "${UNUSABLE}"
fi

# --- Report -------------------------------------------------------------
log ""
log "recovered row counts:"
while read -r table; do
    [ -z "${table}" ] && continue
    n=$(docker exec "${CONTAINER}" mariadb -uroot -N -e \
        "SELECT COUNT(*) FROM \`${DB_NAME}\`.\`${table}\`;" 2>/dev/null | head -1)
    printf '  %-34s %s\n' "${table}" "${n}" | tee -a "${OUT_DIR}/row-counts.txt"
done <<< "$(docker exec "${CONTAINER}" mariadb -uroot -N -e \
    "SELECT table_name FROM information_schema.tables
     WHERE table_schema='${DB_NAME}' ORDER BY table_name;" 2>/dev/null)"

# --- Export -------------------------------------------------------------
log ""
log "dumping the recovered data to SQL"
# The MariaDB image ships `mariadb-dump`, not `mysqldump`.
docker exec "${CONTAINER}" mariadb-dump -uroot --no-create-info \
    --skip-triggers --single-transaction --quick \
    "${DB_NAME}" 2>/dev/null > "${OUT_DIR}/phpbb_data.sql"

log "dumping the schema to SQL"
docker exec "${CONTAINER}" mariadb-dump -uroot --no-data --skip-triggers \
    "${DB_NAME}" 2>/dev/null > "${OUT_DIR}/phpbb_schema.sql"

# --- Keep a clean copy of the repaired data directory -------------------
# This is the repaired MySQL data directory. It can be mounted into a
# MariaDB container to serve the forum without a SQL round trip.
log "keeping the repaired data directory at ${OUT_DIR}/datadir"
mkdir -p "${OUT_DIR}/datadir"
docker exec "${CONTAINER}" sh -c \
    'tar -C /var/lib/mysql -cf - .' 2>/dev/null \
  | tar -C "${OUT_DIR}/datadir" -xf - 2>/dev/null || true

docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
rm -rf "${WORK_DIR}"

log ""
log "done"
log "  data dump   : ${OUT_DIR}/phpbb_data.sql"
log "  schema dump : ${OUT_DIR}/phpbb_schema.sql"
log "  row counts  : ${OUT_DIR}/row-counts.txt"
log "  repaired dir: ${OUT_DIR}/datadir"

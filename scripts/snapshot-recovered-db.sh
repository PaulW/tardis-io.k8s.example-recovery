#!/bin/bash
# =====================================================================
# Take a safety snapshot of the recovered database.
# =====================================================================
# The recovered data is the only copy of the 2016/2017 forum that
# exists. A snapshot means any later experiment (a phpBB upgrade, a
# merge with an older backup) can be thrown away and retried.
#
# Usage:
#   ./scripts/snapshot-recovered-db.sh [label]
#
# Default label: the current date and time.
# =====================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAP_DIR="${REPO_ROOT}/backup_recover/snapshots"
LABEL="${1:-$(date +%Y%m%d-%H%M%S)}"
CONTAINER="phpbb-mariadb"
DB_NAME="${PHPBB_DB_NAME:-phpbb}"
ROOT_PASS="${MARIADB_ROOT_PASSWORD:-root_secret_password}"

mkdir -p "${SNAP_DIR}"
OUT="${SNAP_DIR}/${DB_NAME}-${LABEL}"

log() { echo "[snapshot] $*"; }
die() { echo "[snapshot] ERROR: $*" >&2; exit 1; }

docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$" \
    || die "MariaDB container ${CONTAINER} is not running"

log "dumping ${DB_NAME} to ${OUT}.sql"
docker exec "${CONTAINER}" mariadb-dump -uroot "-p${ROOT_PASS}" \
    --single-transaction --quick --routines --events --triggers \
    "${DB_NAME}" > "${OUT}.sql" 2>/dev/null

# A per-table row count listing, so a later change is easy to see.
docker exec "${CONTAINER}" mariadb -uroot "-p${ROOT_PASS}" -N -e \
    "SELECT table_name, table_rows FROM information_schema.tables
     WHERE table_schema='${DB_NAME}' ORDER BY table_name;" 2>/dev/null \
    > "${OUT}.row-counts.txt" || true

SIZE=$(wc -c < "${OUT}.sql" | tr -d ' ')
log "wrote ${OUT}.sql (${SIZE} bytes)"

# Checksum, so the snapshot can be verified later.
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${OUT}.sql" > "${OUT}.sql.sha256"
    log "checksum: $(cut -d' ' -f1 "${OUT}.sql.sha256")"
fi

log "done"

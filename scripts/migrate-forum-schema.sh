#!/bin/bash
# =====================================================================
# Migrate the recovered forum database to the phpBB 3.3.19 schema.
# =====================================================================
# The recovered database is phpBB 3.1.9. The container runs 3.3.19.
# phpBB's updater requires an EXACT version match, so the migration
# runs in two steps, because that is how phpBB publishes the update
# packages:
#
#   3.1.9  ->  3.1.12   phpBB-3.1.9_to_3.1.12.tar.bz2
#   3.1.12 ->  3.3.19   phpBB-3.1.12_to_3.3.19.tar.bz2
#
# The two steps use different updaters:
#
#   * 3.1.x has no console updater. The updater is the web script
#     install/database_update.php, which runs the migration in stages
#     and stops when it runs out of time, so it has to be driven in a
#     loop until it reports that it is done.
#
#   * 3.2 and later have install/phpbbcli.php, which runs the whole
#     update in one go.
#
# The update files are not in the phpBB release tarball. They are
# published separately and go into install/update/new/ and
# install/update/old/.
#
# The packages are downloaded from download.phpbb.com and verified
# against the SHA256 that phpBB publishes beside them.
#
# The 3.1.9 code cannot run on PHP 8. It ships symfony/yaml v2.3,
# which uses the $string{1} syntax that PHP 8 removed. The image
# ships symfony/yaml v3.4, which parses on PHP 8, so the vendor
# directory is kept from the image and only the phpBB code is
# overlaid.
#
# Usage:
#   ./scripts/migrate-forum-schema.sh
# =====================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHPBB_DIR="${REPO_ROOT}/app-code/phpbb"
CACHE_DIR="${REPO_ROOT}/backup_recover/update-packages"
DB_NAME="${PHPBB_DB_NAME:-phpbb}"
DB_USER="${PHPBB_DB_USER:-phpbb}"
DB_PASS="${PHPBB_DB_PASS:-phpbb_secret_password}"

BASE_URL="https://download.phpbb.com/pub/release"

# The three packages. The first is the code for the version being
# upgraded from, the other two are the update packages.
CODE_3_1_9="phpbb-3.1.9.tar.bz2"
CODE_3_1_9_URL="${BASE_URL}/3.1/3.1.9/${CODE_3_1_9}"

UPDATE_1="${PHPBB_UPDATE_1:-phpBB-3.1.9_to_3.1.12.tar.bz2}"
UPDATE_1_URL="${BASE_URL}/3.1/3.1.12/${UPDATE_1}"

UPDATE_2="${PHPBB_UPDATE_2:-phpBB-3.1.12_to_3.3.19.tar.bz2}"
UPDATE_2_URL="${BASE_URL}/3.3/3.3.19/${UPDATE_2}"

log() { echo "[migrate] $*"; }
die() { echo "[migrate] ERROR: $*" >&2; exit 1; }

# --- Fetch a package and verify it -------------------------------------
# The checksum is published beside the package as a .sha256 file.
fetch() {
    local name="$1" url="$2"
    local target="${CACHE_DIR}/${name}"

    if [ -f "${target}" ]; then
        log "  ${name} is already cached"
        return 0
    fi

    log "  downloading ${name}"
    curl -fsSL --max-time 300 "${url}" -o "${target}" \
        || die "could not download ${url}"

    local expected actual
    expected=$(curl -fsSL --max-time 60 "${url}.sha256" 2>/dev/null \
        | grep -oE '[a-f0-9]{64}' | head -1)
    [ -n "${expected}" ] || die "no checksum published for ${name}"

    actual=$(shasum -a 256 "${target}" | awk '{print $1}')
    [ "${expected}" = "${actual}" ] \
        || die "checksum mismatch for ${name}: expected ${expected}, got ${actual}"
    log "  ${name} verified (sha256 ${actual:0:16}...)"
}

# --- Read the database version -----------------------------------------
db_version() {
    docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e \
        "SELECT config_value FROM ${DB_NAME}.phpbb_config
         WHERE config_name = 'version';" 2>/dev/null | head -1
}

cd "${PHPBB_DIR}" || die "cannot find ${PHPBB_DIR}"

CONTAINER=$(docker compose ps -q mariadb 2>/dev/null | head -1)
[ -n "${CONTAINER}" ] || die "the mariadb container is not running"

log "the database version before: $(db_version)"

mkdir -p "${CACHE_DIR}"
log "fetching the packages"
fetch "${CODE_3_1_9}" "${CODE_3_1_9_URL}"
fetch "${UPDATE_1}" "${UPDATE_1_URL}"
fetch "${UPDATE_2}" "${UPDATE_2_URL}"

# The packages are mounted from the cache directory.
for name in "${CODE_3_1_9}" "${UPDATE_1}" "${UPDATE_2}"; do
    cp "${CACHE_DIR}/${name}" "/tmp/${name}"
done

# --- The 3.1.x step ----------------------------------------------------
# The 3.1.9 updater is the web script install/database_update.php. It
# has no console form in this version, so it is driven in a loop: it
# runs the migration in stages and stops when it runs out of time.
#
# The updater has to run against the 3.1.9 code, because it copies the
# files it replaces out of the running install. So the 3.1.9 code is
# put in place first, and the update files are added on top.
log ""
log "=== 3.1.9 -> 3.1.12 ==="

# The style tables have to exist before the updater runs. The forum
# was upgraded from 3.0.x, and the 3.1.0 upgrade split the style
# into a template, a theme and an imageset. The 3.1.9 database does
# not have those tables, and the updater needs them.
STYLE_TABLES="${REPO_ROOT}/backup_recover/recovered/missing-style-tables.sql"
if [ -f "${STYLE_TABLES}" ]; then
    log "  creating the missing style tables"
    docker exec -i "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" \
        "${DB_NAME}" < "${STYLE_TABLES}" 2>/dev/null || true
fi

# The 3.1.9 database is a 3.0.x -> 3.1.x hybrid. The upgrade never
# completed, so a few tables that the 3.1.x migrations need are
# missing.
EXTRA_TABLES="${REPO_ROOT}/backup_recover/recovered/missing-3.1-tables.sql"
if [ -f "${EXTRA_TABLES}" ]; then
    log "  creating the missing 3.1.x tables"
    docker exec -i "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" \
        "${DB_NAME}" < "${EXTRA_TABLES}" 2>/dev/null || true
fi

docker compose run --rm --no-deps \
    -e PHPBB_RUN_INSTALLER=false \
    -e PHPBB_DB_NAME="${DB_NAME}" \
    -e PHPBB_DB_USER="${DB_USER}" \
    -e PHPBB_DB_PASS="${DB_PASS}" \
    -v "/tmp/${CODE_3_1_9}:/tmp/${CODE_3_1_9}:ro" \
    -v "/tmp/${UPDATE_1}:/tmp/${UPDATE_1}:ro" \
    --entrypoint sh phpbb-installer -c "
        set -e
        cd /var/www/html

        # Put the 3.1.9 code in place. The mounted paths are left
        # alone: files, images, store and ext are volumes, so they
        # cannot be removed, and the update does not replace them.
        #
        # The vendor directory is kept from the image. The 3.1.9
        # release ships symfony/yaml v2.3, which does not parse on
        # PHP 8.
        find /var/www/html -mindepth 1 -maxdepth 1 \
            ! -name config.php.template ! -name config.php ! -name cache \
            ! -name files ! -name images ! -name store ! -name vendor \
            ! -name ext -exec rm -rf {} +
        tar -xjf /tmp/${CODE_3_1_9} --strip-components=1 -C /var/www/html \
            --exclude='phpBB3/vendor/*'

        # The updater needs a config.php and no install lock.
        rm -f cache/install_lock
        sed 's|@@PHPBB_INSTALLED_BLOCK@@|@define('\''PHPBB_INSTALLED'\'', true);|' \
            config.php.template > config.php
        chmod 640 config.php

        # The update package holds the new code and the old code. Only
        # the update directory is extracted: the rest of the package
        # is the new release, and it would overwrite the 3.1.9 code
        # that the updater has to run against.
        rm -rf install/update
        tar -xjf /tmp/${UPDATE_1} -C /var/www/html install/update
        echo \"  new: \$(find install/update/new -type f | wc -l)  old: \$(find install/update/old -type f | wc -l)\"

        echo '--- running the updater ---'
        # The updater resolves its root path as './../', relative to
        # the working directory, so it has to be run from install/.
        #
        # The 3.1.x updater installs ONE migration per run and then
        # stops, because it is written for a web request that the
        # administrator follows. The state is kept in the
        # phpbb_migrations table, so each run picks up where the last
        # one stopped. The loop runs it until it reports that the
        # update is complete.
        for attempt in \$(seq 1 300); do
            out=\$(cd install && php database_update.php 2>&1)
            if echo \"\$out\" | grep -q 'Database updater has completed'; then
                echo '  the update is complete'
                break
            fi
            if echo \"\$out\" | grep -qiE 'Fatal error|Parse error|Uncaught'; then
                echo \"\$out\" | tail -25
                exit 1
            fi
            done=\$(echo \"\$out\" | grep -oE 'Installed Data: [^;]*' | head -1)
            if [ -n \"\$done\" ]; then
                echo \"  \$done\"
            fi
        done
    " 2>&1 | tail -40

log ""
log "the database version now: $(db_version)"

# --- The 3.3.x step ----------------------------------------------------
# This step uses the console updater, which runs the whole update in
# one go.
#
# The updater is run in db_only mode, so it does not touch the
# filesystem: the container already has the 3.3.19 code, and the
# update package's copy of the files is only needed for a real
# upgrade from an installed 3.1.12 board.
#
# The console updater runs the migrations from its own code. That
# matters, because the 3.1.9 code only has the migrations up to
# v319rc1, and the v3110, v3111 and v3112 migrations are the ones
# that move the version on from 3.1.9.
log ""
log "=== 3.1.12 -> 3.3.19 ==="

# The updater checks the version in the database against the version
# in the update package. The 3.1.x web updater does not write the
# version, so it is set here to the version the package expects.
log "  setting the version to 3.1.12"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e \
    "UPDATE ${DB_NAME}.phpbb_config SET config_value = '3.1.12'
     WHERE config_name = 'version';" 2>/dev/null

docker compose run --rm --no-deps \
    -e PHPBB_RUN_INSTALLER=false \
    -e PHPBB_INSTALLED=true \
    -e PHPBB_DB_NAME="${DB_NAME}" \
    -e PHPBB_DB_USER="${DB_USER}" \
    -e PHPBB_DB_PASS="${DB_PASS}" \
    -v "/tmp/${UPDATE_2}:/tmp/${UPDATE_2}:ro" \
    --entrypoint sh phpbb-installer -c "
        set -e
        cd /var/www/html

        rm -f cache/install_lock
        sed 's|@@PHPBB_INSTALLED_BLOCK@@|@define('\''PHPBB_INSTALLED'\'', true);|' \
            config.php.template > config.php
        chmod 640 config.php

        rm -rf install/update
        tar -xjf /tmp/${UPDATE_2} -C /var/www/html install/update
        echo \"  new: \$(find install/update/new -type f | wc -l)  old: \$(find install/update/old -type f | wc -l)\"

        printf 'updater:\n    type: db_only\n    extensions: []\n' > /tmp/update.yml
        echo '--- running the updater ---'
        php install/phpbbcli.php update /tmp/update.yml --no-interaction
    " 2>&1 | grep -vE '^\s*[0-9]+/[0-9]+' | tail -30

log ""
log "the database version after: $(db_version)"
log "done"
log ""
log "The data needs a repair before the forum can serve it."
log "Run ./scripts/repair-recovered-forum.sh next."

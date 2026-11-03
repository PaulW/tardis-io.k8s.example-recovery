#!/bin/bash
# =====================================================================
# Repair the recovered forum database after the 3.3.19 migration.
# =====================================================================
# The merged database came from two backups. Each needed a repair
# that the phpBB schema migration does not do, because the migration
# only knows the shape of the schema, not the shape of the data.
#
# 1. The orphaned bots
#    The 2016 backup has 19 bot rows whose user_id points at a user
#    that was never recovered. The bot cache reads those rows, and
#    the session code treats a matching user agent as a bot. A curl
#    request therefore looked up a user that does not exist, and the
#    session came back empty. The forum then rendered as a guest with
#    no permissions, so it showed no forums at all.
#
# 2. The nested set
#    The 2013 and 2016 forum trees were merged without rebuilding the
#    left_id and right_id values, so four pairs of forums share the
#    same values. phpBB reads the tree with a nested set query, so a
#    broken tree means no forums on the board index.
#
# 3. The post visibility
#    The 2013 backup has post_approved, where 1 means approved. The
#    2016 backup has post_visibility, where 0 meant visible at the
#    time. phpBB 3.3 uses ITEM_APPROVED = 1 and ITEM_UNAPPROVED = 0,
#    the other way round, so every recovered post was marked
#    unapproved and no topic would open.
#
# 4. The system cron
#    The board runs its scheduled tasks from a Kubernetes CronJob, so
#    phpBB must not run them itself. phpBB runs them opportunistically,
#    by putting a hidden image tag in the page and letting the
#    browser fetch it, and the URL is blocked by Cloudflare, so every
#    visitor got a 403.
#
# Usage:
#   ./scripts/repair-recovered-forum.sh
# =====================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHPBB_DIR="${REPO_ROOT}/app-code/phpbb"
DB_NAME="${PHPBB_DB_NAME:-phpbb}"
DB_USER="${PHPBB_DB_USER:-phpbb}"
DB_PASS="${PHPBB_DB_PASS:-phpbb_secret_password}"
ROOT_PASS="${MARIADB_ROOT_PASSWORD:-root_secret_password}"
# The board's founder. The script makes this member the founder,
# because the recovered board has none and phpBB grants every
# administration permission from the founder flag alone.
FOUNDER_USERNAME="${FOUNDER_USERNAME:?the founder's username is required}"

log() { echo "[repair] $*"; }
die() { echo "[repair] ERROR: $*" >&2; exit 1; }

cd "${PHPBB_DIR}" || die "cannot find ${PHPBB_DIR}"

CONTAINER=$(docker compose ps -q mariadb 2>/dev/null | head -1)
[ -n "${CONTAINER}" ] || die "the mariadb container is not running"

# --- 1. The orphaned bots ---------------------------------------------
# A bot row is orphaned when its user_id has no matching user. The
# rows are removed, because the bot they point at does not exist.
log "removing the orphaned bot rows"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    DELETE FROM ${DB_NAME}.phpbb_bots
    WHERE user_id NOT IN (SELECT user_id FROM ${DB_NAME}.phpbb_users);
" 2>/dev/null

ORPHANS=$(docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e "
    SELECT COUNT(*)
    FROM ${DB_NAME}.phpbb_bots b
    LEFT JOIN ${DB_NAME}.phpbb_users u ON u.user_id = b.user_id
    WHERE u.user_id IS NULL;
" 2>/dev/null)
log "  orphaned bots left: ${ORPHANS}"

# --- 2. The nested set -------------------------------------------------
log "rebuilding the forum nested set"
docker compose run --rm --no-deps \
    -e PHPBB_RUN_INSTALLER=false \
    -e PHPBB_INSTALLED=true \
    -e PHPBB_DB_NAME="${DB_NAME}" \
    -e PHPBB_DB_USER="${DB_USER}" \
    -e PHPBB_DB_PASS="${DB_PASS}" \
    -v "${REPO_ROOT}/scripts/rebuild-forum-tree.php:/tmp/rebuild-forum-tree.php:ro" \
    --entrypoint sh phpbb-installer -c "
        cd /var/www/html
        sed 's|@@PHPBB_INSTALLED_BLOCK@@|@define('\''PHPBB_INSTALLED'\'', true);|' \
            config.php.template > config.php
        chmod 640 config.php
        php /tmp/rebuild-forum-tree.php
    " 2>&1 | grep -v "level=warning" | sed 's/^/  /'

# --- 3. The post visibility -------------------------------------------
# The migration does not change the visibility values, because it has
# no way of knowing that the 2016 backup used the other convention.
#
# The 2016 backup used the opposite convention. In the 2016 schema,
# post_visibility = 0 meant a visible post and 1 meant an unapproved
# one. phpBB 3.3 uses ITEM_APPROVED = 1 and ITEM_UNAPPROVED = 0.
#
# The merge maps the 2013 posts, which have post_approved, so the
# posts that came from the 2013 dump have the right values. Only the
# posts that are unique to the 2016 backup need the swap.
#
# Without this, 1,421 posts from 2015 and 2016 are hidden, and the
# 146 topics that hold only those posts cannot be opened at all.
#
# The swap is guarded, so it only runs when the data still needs it.
# The test is the number of topics that have no visible post. A
# healthy forum has none, because a topic needs a post to open.
log "checking the post visibility"
HIDDEN=$(docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e "
    SELECT COUNT(*)
    FROM ${DB_NAME}.phpbb_topics t
    WHERE NOT EXISTS (
        SELECT 1 FROM ${DB_NAME}.phpbb_posts p
        WHERE p.topic_id = t.topic_id AND p.post_visibility = 1
    );
" 2>/dev/null)
log "  the topics that have no visible post: ${HIDDEN}"

if [ "${HIDDEN:-0}" -gt 0 ]; then
    log "  the data uses the old convention, swapping the values"
    # The 2013 dump is not always there, so the posts that came from
    # it are found by the post ids instead. The swap is only run on
    # the posts that the 2013 dump does not have, so it is safe to
    # run after the merge has already done the same thing.
    docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
        UPDATE ${DB_NAME}.phpbb_posts
        SET post_visibility = 1 - post_visibility
        WHERE post_visibility IN (0, 1)
          AND post_id NOT IN (
              SELECT post_id FROM phpbb_2013.phpbb_posts
          );
    " 2>/dev/null || true
else
    log "  the data already uses the phpBB 3.3 convention"
fi

# --- 3b. The posts the forum was moderating ---------------------------
# The 2013 dump has 187 posts that the forum's moderators had not
# approved. The decision was taken to publish them, so that the
# recovered forum shows everything the board once showed.
log "publishing the posts that the forum was moderating"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_posts
    SET post_visibility = 1
    WHERE post_visibility = 0;
" 2>/dev/null

UNAPPROVED=$(docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e "
    SELECT COUNT(*) FROM ${DB_NAME}.phpbb_posts WHERE post_visibility = 0;
" 2>/dev/null)
log "  the unapproved posts left: ${UNAPPROVED}"

# --- 4. The counters ---------------------------------------------------
# The topic and forum counters hold the number of approved posts and
# topics. They are recomputed from the rows, because the merge and
# the visibility swap both leave them stale.
log "recomputing the topic and forum counters"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_topics t
    SET t.topic_posts_approved = (
            SELECT COUNT(*) FROM ${DB_NAME}.phpbb_posts p
            WHERE p.topic_id = t.topic_id AND p.post_visibility = 1
        ),
        t.topic_posts_unapproved = (
            SELECT COUNT(*) FROM ${DB_NAME}.phpbb_posts p
            WHERE p.topic_id = t.topic_id AND p.post_visibility = 0
        );

    UPDATE ${DB_NAME}.phpbb_forums f
    SET f.forum_posts_approved = (
            SELECT COUNT(*) FROM ${DB_NAME}.phpbb_posts p
            WHERE p.forum_id = f.forum_id AND p.post_visibility = 1
        ),
        f.forum_posts_unapproved = (
            SELECT COUNT(*) FROM ${DB_NAME}.phpbb_posts p
            WHERE p.forum_id = f.forum_id AND p.post_visibility = 0
        ),
        f.forum_topics_approved = (
            SELECT COUNT(*) FROM ${DB_NAME}.phpbb_topics t
            WHERE t.forum_id = f.forum_id AND t.topic_visibility = 1
        ),
        f.forum_topics_unapproved = (
            SELECT COUNT(*) FROM ${DB_NAME}.phpbb_topics t
            WHERE t.forum_id = f.forum_id AND t.topic_visibility = 0
        );
" 2>/dev/null

# --- 4b. The server settings ---------------------------------------------
# The board settings came out of the 2016 backup, so they point at the
# production site. That breaks the forum when it is served anywhere
# else, because phpBB then:
#
#   * sets the session cookie for .forum.example.com, so a browser on any
#     other host throws the cookie away and nobody can log in;
#   * marks the cookie as secure, so it is not sent over plain HTTP;
#   * builds every link with the forum.example.com host name, so the "I
#     forgot my password" link points at a page that does not exist
#     on the host that is actually serving the forum.
#
# The values are read from the environment, so the same image works
# locally and in the cluster. The defaults here are the ones the
# local stack uses.
#
# This step runs before the cache is cleared, because the config is
# cached on disk and the new values have to be in place before the
# cache is rebuilt.
SERVER_NAME="${PHPBB_SERVER_NAME:-localhost}"
SERVER_PORT="${PHPBB_SERVER_PORT:-8080}"
SERVER_PROTOCOL="${PHPBB_SERVER_PROTOCOL:-http://}"
SCRIPT_PATH="${PHPBB_SCRIPT_PATH:-/}"
COOKIE_SECURE="${PHPBB_COOKIE_SECURE:-false}"

# phpBB stores this as a number, and a non-empty string is truthy in
# PHP. The word "false" would turn the secure flag on, so it has to
# be turned into a 0 or a 1.
case "${COOKIE_SECURE}" in
    true|1)  COOKIE_SECURE=1 ;;
    false|0) COOKIE_SECURE=0 ;;
    *) die "PHPBB_COOKIE_SECURE must be 'true' or 'false', got '${COOKIE_SECURE}'" ;;
esac

log "setting the server settings to ${SERVER_NAME}:${SERVER_PORT} (${SERVER_PROTOCOL})"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_config
    SET config_value = '${SERVER_NAME}' WHERE config_name = 'server_name';
    UPDATE ${DB_NAME}.phpbb_config
    SET config_value = '${SERVER_PORT}' WHERE config_name = 'server_port';
    UPDATE ${DB_NAME}.phpbb_config
    SET config_value = '${SERVER_PROTOCOL}' WHERE config_name = 'server_protocol';
    UPDATE ${DB_NAME}.phpbb_config
    SET config_value = '${SCRIPT_PATH}' WHERE config_name = 'script_path';
    UPDATE ${DB_NAME}.phpbb_config
    SET config_value = '${COOKIE_SECURE}' WHERE config_name = 'cookie_secure';
    UPDATE ${DB_NAME}.phpbb_config
    SET config_value = '' WHERE config_name = 'cookie_domain';
    UPDATE ${DB_NAME}.phpbb_config
    SET config_value = '0' WHERE config_name = 'force_server_vars';
" 2>/dev/null

docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e "
    SELECT CONCAT('  ', config_name, ' = ', config_value)
    FROM ${DB_NAME}.phpbb_config
    WHERE config_name IN ('server_name', 'server_port', 'server_protocol',
                          'script_path', 'cookie_secure', 'cookie_domain',
                          'force_server_vars');
" 2>/dev/null | sed 's/^/  /'

# --- 5. The cache ------------------------------------------------------
# The bot list, the ACLs and the role cache are all cached on disk.
# The cache lives in cache/production/, not cache/data/.
log "clearing the forum cache"
docker compose exec -T phpbb sh -c \
    'rm -f /var/www/html/cache/production/data_*.php /var/www/html/cache/production/data_*.php.lock' \
    2>/dev/null || true

# --- 5b. The poster metadata -------------------------------------------
# The topic and the forum rows hold the name, the colour and the time
# of the first and the last post. The merge and the visibility swap
# both leave them stale, so they are taken from the posts.
#
# The member post counts are stale for the same reason. The recovered
# posts were never counted, so most of the counts are too low.
log "recomputing the poster metadata"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_posts p
    JOIN ${DB_NAME}.phpbb_users u ON u.user_id = p.poster_id
    SET p.post_username = u.username
    WHERE p.post_username <> u.username AND u.username <> '';

    UPDATE ${DB_NAME}.phpbb_topics t
    JOIN ${DB_NAME}.phpbb_posts p ON p.post_id = t.topic_first_post_id
    LEFT JOIN ${DB_NAME}.phpbb_users u ON u.user_id = p.poster_id
    SET t.topic_first_poster_name = p.post_username,
        t.topic_first_poster_colour = COALESCE(u.user_colour, '');

    UPDATE ${DB_NAME}.phpbb_topics t
    JOIN ${DB_NAME}.phpbb_posts p ON p.post_id = t.topic_last_post_id
    LEFT JOIN ${DB_NAME}.phpbb_users u ON u.user_id = p.poster_id
    SET t.topic_last_poster_name = p.post_username,
        t.topic_last_poster_id = p.poster_id,
        t.topic_last_poster_colour = COALESCE(u.user_colour, ''),
        t.topic_last_post_subject = p.post_subject,
        t.topic_last_post_time = p.post_time;

    UPDATE ${DB_NAME}.phpbb_forums f
    JOIN ${DB_NAME}.phpbb_posts p ON p.post_id = f.forum_last_post_id
    SET f.forum_last_post_subject = p.post_subject,
        f.forum_last_poster_id = p.poster_id,
        f.forum_last_poster_name = p.post_username,
        f.forum_last_post_time = p.post_time;

    UPDATE ${DB_NAME}.phpbb_users u
    SET u.user_posts = (
            SELECT COUNT(*) FROM ${DB_NAME}.phpbb_posts p
            WHERE p.poster_id = u.user_id AND p.post_visibility = 1
        )
    WHERE u.user_posts <> (
            SELECT COUNT(*) FROM ${DB_NAME}.phpbb_posts p
            WHERE p.poster_id = u.user_id AND p.post_visibility = 1
        );
" 2>/dev/null

# --- 6. The birthdays ---------------------------------------------------
# The recovered member rows carry the old phpBB "no birthday" marker
# and the old padded format. phpBB 3.3 splits the value on the dash
# and reads the first part as the day, so a value that is not three
# numbers raises a warning on every post the member wrote.
#
# The old marker is " 0- 0-   0". The old format padded the parts
# with spaces, and the placeholder rows hold two apostrophes. All of
# them are cleared, and the rest is stripped of its padding.
log "normalising the member birthdays"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_users
    SET user_birthday = ''
    WHERE user_birthday <> ''
      AND HEX(user_birthday) IN ('2727', '2020', '20302D302D203020');

    UPDATE ${DB_NAME}.phpbb_users
    SET user_birthday = REPLACE(user_birthday, ' ', '')
    WHERE user_birthday <> '' AND user_birthday LIKE '% %';
" 2>/dev/null

MALFORMED=$(docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e "
    SELECT COUNT(*)
    FROM ${DB_NAME}.phpbb_users
    WHERE user_birthday <> ''
      AND user_birthday NOT REGEXP '^[0-9]{1,2}-[0-9]{1,2}-[0-9]{4}\$';
" 2>/dev/null)
log "  malformed birthdays left: ${MALFORMED}"

# --- 7. The placeholder member rows ------------------------------------
# The recovered member rows were written with a literal pair of
# apostrophes in every text column, because the loader quoted the
# default value that information_schema reports. A column that holds
# the two characters of a pair of apostrophes cannot be read by
# phpBB, and the member's posts fail to render.
#
# The values are cleared, and the ones that phpBB needs are set to
# the board defaults. The language, the timezone and the colour are
# not known, and the registration date is not known either, so the
# board start date is used for it.
log "clearing the placeholder member values"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_users
    SET user_ip = '', user_email = '', user_lastpage = '',
        user_last_confirm_key = '', user_timezone = '', user_colour = '',
        user_avatar_type = '', user_sig_bbcode_uid = '',
        user_sig_bbcode_bitfield = '', user_jabber = '', user_actkey = '',
        user_newpasswd = '', user_form_salt = '', user_password = ''
    WHERE HEX(user_ip) = '2727';

    UPDATE ${DB_NAME}.phpbb_users SET user_lang = 'en' WHERE user_lang = '';
    UPDATE ${DB_NAME}.phpbb_users
        SET user_timezone = 'Europe/London' WHERE user_timezone = '';
    UPDATE ${DB_NAME}.phpbb_users SET user_colour = '000000' WHERE user_colour = '';
    UPDATE ${DB_NAME}.phpbb_users SET user_avatar_type = '0' WHERE user_avatar_type = '';
    UPDATE ${DB_NAME}.phpbb_users
        SET user_regdate = (SELECT config_value FROM ${DB_NAME}.phpbb_config
                            WHERE config_name = 'board_startdate')
        WHERE user_regdate = 0;
" 2>/dev/null

# The four sort columns are the ones that break the forum for a
# member. The loader quoted the default that information_schema
# reports, and the default of a one character column comes back as
# the three characters 't', with the quotes included. The column
# therefore holds a single apostrophe, which is not one of the
# values phpBB sorts by.
#
# The sort key is read when a member opens a topic, and phpBB builds
# the sort order from it. A key it does not know gives an empty
# ORDER BY, and the topic fails to open with a SQL error. This is
# what stopped the administrator from reading the site notice.
#
# The date format has the same problem. The loader quoted the
# default, so the column held the default with its quotes included.
# The quote is stripped and the format is set to one that shows the
# day of the month. The schema default is 'd M Y H:i', which has the
# day of the month but no day of the week, and the format set here
# has both:
#
#     D    the day of the week
#     M    the month
#     d    the DAY OF THE MONTH
#     Y    the year
#     H:i  the hour and the minute
#
# The format must have the lower case 'd' in it. A format of
# 'D M Y H:i' has no day of the month at all, so every date the
# member saw was missing the day, and read as 'Thu Nov 2004 16:32'
# instead of 'Thu Nov 24 2004 16:32'.
#
# The columns are set to the board defaults, which are the same
# values the schema holds.
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_users
    SET user_topic_sortby_type = 't' WHERE HEX(user_topic_sortby_type) = '27';
    UPDATE ${DB_NAME}.phpbb_users
    SET user_topic_sortby_dir = 'd' WHERE HEX(user_topic_sortby_dir) = '27';
    UPDATE ${DB_NAME}.phpbb_users
    SET user_post_sortby_type = 't' WHERE HEX(user_post_sortby_type) = '27';
    UPDATE ${DB_NAME}.phpbb_users
    SET user_post_sortby_dir = 'a' WHERE HEX(user_post_sortby_dir) = '27';
    UPDATE ${DB_NAME}.phpbb_users
    SET user_dateformat = 'D M d Y H:i'
    WHERE HEX(user_dateformat) = '2764204D205920483A6927'
       OR HEX(user_dateformat) = '44204D205920483A69';
" 2>/dev/null

LITERAL=$(docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e "
    SELECT COUNT(*)
    FROM ${DB_NAME}.phpbb_users
    WHERE HEX(user_ip) = '2727' OR HEX(user_lang) = '2727'
       OR HEX(user_topic_sortby_type) = '27'
       OR HEX(user_topic_sortby_dir) = '27'
       OR HEX(user_post_sortby_type) = '27'
       OR HEX(user_post_sortby_dir) = '27'
       OR HEX(user_dateformat) = '2764204D205920483A6927'
       OR HEX(user_dateformat) = '44204D205920483A69';
" 2>/dev/null)
log "  the placeholder rows left: ${LITERAL}"

# --- 8. The members that the content refers to ------------------------
# The 2013 dump was truncated during the phpbb_sessions_keys table, so
# it has no phpbb_users table at all. The members who wrote the 2013
# posts and the private messages are therefore missing, and phpBB
# cannot render a post whose author is missing.
#
# The names are not recoverable, so each member gets a placeholder row
# that holds the id and nothing else.
log "creating the member rows that the content refers to"
MARIADB_CONTAINER="${CONTAINER}" PHPBB_DB_NAME="${DB_NAME}" \
    MARIADB_ROOT_PASSWORD="${ROOT_PASS}" \
    python3 "${REPO_ROOT}/scripts/create-missing-users.py" "${DB_NAME}" \
    2>&1 | sed 's/^/  /' || true

# --- 8b. The member types ----------------------------------------------
# The recovered members were written with user_type = 2, which is
# USER_IGNORE. That is the type phpBB uses for a bot, so the members
# were treated as bots and were left out of the member list.
#
# The decision was taken to show them as normal members. The name is
# the one field that identifies a member to a reader, so marking them
# as deleted accounts would make their posts look like they came from
# nowhere.
#
# The bots keep their type. A user is a bot when it is in the bots
# table.
log "setting the recovered members to normal members"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_users
    SET user_type = 0
    WHERE user_type = 2
      AND user_id NOT IN (SELECT user_id FROM ${DB_NAME}.phpbb_bots);
" 2>/dev/null

# The 1,277 members whose name is not known are given a name that
# says so, rather than a bare number.
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_users
    SET username = CONCAT('Former member ', user_id),
        username_clean = CONCAT('former member ', user_id)
    WHERE username LIKE 'Unknown member %';
" 2>/dev/null

BOTS=$(docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e "
    SELECT COUNT(*) FROM ${DB_NAME}.phpbb_users WHERE user_type = 2;
" 2>/dev/null)
log "  the members still typed as a bot: ${BOTS}"

# The default group of a member is the one they are a member of. The
# recovered members were written with the REGISTERED_COPPA group as
# their default, which is the group a member under the age of consent
# belongs to. They are all in the REGISTERED group, so their default
# is set to that.
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_users u
    JOIN ${DB_NAME}.phpbb_user_group ug ON ug.user_id = u.user_id
    SET u.group_id = ug.group_id
    WHERE u.user_type = 0
      AND ug.group_id IN (2, 8)
      AND u.group_id NOT IN (2, 8);
" 2>/dev/null

# --- 9. The post and topic metadata -----------------------------------
# The posts of a member whose row is a placeholder have no username,
# and the topic rows hold a poster name that does not match the post.
# The usernames are taken from the member rows, and the poster names
# are taken from the posts.
log "filling in the missing post and topic names"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_posts p
    JOIN ${DB_NAME}.phpbb_users u ON u.user_id = p.poster_id
    SET p.post_username = u.username
    WHERE p.post_username = '' AND u.username <> '';

    UPDATE ${DB_NAME}.phpbb_topics t
    JOIN ${DB_NAME}.phpbb_posts p ON p.post_id = t.topic_first_post_id
    SET t.topic_first_poster_name = p.post_username
    WHERE t.topic_first_poster_name <> p.post_username;

    UPDATE ${DB_NAME}.phpbb_topics t
    JOIN ${DB_NAME}.phpbb_posts p ON p.post_id = t.topic_last_post_id
    SET t.topic_last_poster_name = p.post_username
    WHERE t.topic_last_poster_name <> p.post_username;
" 2>/dev/null

# --- 10. The dangling references ---------------------------------------
# A topic that has no posts cannot be opened, and phpBB answers it
# with "The requested topic does not exist.". The 2016 damage took
# the posts out of 1,162 topics but left the topic rows.
#
# The topics are deleted with phpBB's own delete_topics function, so
# the watches, the read markers and the counters are handled the way
# the board handles a deletion from the administration panel.
log "dropping the topics that have no posts"
docker compose run --rm --no-deps \
    -e PHPBB_RUN_INSTALLER=false \
    -e PHPBB_INSTALLED=true \
    -e PHPBB_DB_NAME="${DB_NAME}" \
    -e PHPBB_DB_USER="${DB_USER}" \
    -e PHPBB_DB_PASS="${DB_PASS}" \
    -v "${REPO_ROOT}/scripts/drop-empty-topics.php:/tmp/drop-empty-topics.php:ro" \
    --entrypoint sh phpbb-installer -c "
        cd /var/www/html
        sed 's|@@PHPBB_INSTALLED_BLOCK@@|@define('\''PHPBB_INSTALLED'\'', true);|' \
            config.php.template > config.php
        chmod 640 config.php
        php /tmp/drop-empty-topics.php
    " 2>&1 | grep -v "level=warning" | sed 's/^/  /'

# --- 10b. The staff designations ---------------------------------------
# phpBB shows a member's rank and colour from the group named in
# phpbb_users.group_id, not from the groups the member belongs to.
# The 3.3 migration reset every default group to REGISTERED, so the
# administrators and the moderators lost the default that carries
# their rank and their colour. They were in the right group, but
# they read as ordinary members under their own name.
#
# The script also restores the name of the members whose user row was
# destroyed, and rebuilds the moderator cache with phpBB's own
# function, so the forum pages list the moderators again.
log "restoring the admin and moderator designations"
docker compose run --rm --no-deps \
    -e PHPBB_RUN_INSTALLER=false \
    -e PHPBB_INSTALLED=true \
    -e PHPBB_DB_NAME="${DB_NAME}" \
    -e PHPBB_DB_USER="${DB_USER}" \
    -e PHPBB_DB_PASS="${DB_PASS}" \
    -e MARIADB_ROOT_PASSWORD="${ROOT_PASS}" \
    -v "${REPO_ROOT}/scripts/restore-staff-roles.php:/tmp/restore-staff-roles.php:ro" \
    --entrypoint sh phpbb-installer -c "
        cd /var/www/html
        sed 's|@@PHPBB_INSTALLED_BLOCK@@|@define('\''PHPBB_INSTALLED'\'', true);|' \
            config.php.template > config.php
        chmod 640 config.php
        php /tmp/restore-staff-roles.php
    " 2>&1 | grep -v "level=warning" | sed 's/^/  /'

# --- 10c. The original case of the member names ------------------------
# The index recovery read the names from the username_clean index, and
# that column holds the lowercase name by definition in phpBB. So the
# members whose user row was destroyed have a lowercase name, and the
# original case has to come from the forum's own caches.
#
# The script reads the snapshots that were taken before the repair
# overwrote the topic, forum and post names, and the 2013 database.
# A name is only used when it matches the member's current name,
# ignoring the case, so a member is never renamed to a different
# member's name.
log "restoring the original case of the member names"
python3 "${REPO_ROOT}/scripts/recover-username-case.py" "${DB_NAME}" 2>&1 | sed 's/^/  /'

# --- 10d. The member avatars -------------------------------------------
# The web backup holds the avatar store of the forum: 779 files for
# 390 members. The members whose user row was destroyed lost the
# avatar with it, so the file is in the backup but the row does not
# point at it.
#
# The file name on disk is the phpBB name, `<salt>_<user_id>.<ext>`.
# The name in the row is the one phpBB 3.3 writes, which is the user
# id and the time the avatar was uploaded, without the salt. phpBB
# adds the salt when it serves the file.
log "restoring the member avatars"
python3 "${REPO_ROOT}/scripts/recover-avatars.py" "${DB_NAME}" 2>&1 | sed 's/^/  /'

# --- 10e. The names of the members whose row was destroyed -------------
# There are 1,234 members on the board who are called "Former member N".
# Their id is real, because the content refers to it, but their name is
# not known. The index recovery did not hold a name for them.
#
# The name is in the forum's own caches, which store the name of the
# poster next to their id: the topic rows, the forum rows, the post
# rows and the moderator cache. The snapshots taken before the repair
# overwrote those names hold the 2016 values, and the 2013 database
# holds the 2013 values.
#
# A name is only used when every source agrees on it and no other
# member already has it, so a member is never renamed onto another
# member's name.
log "naming the members whose name is not known"
python3 "${REPO_ROOT}/scripts/recover-lost-member-names.py" "${DB_NAME}" 2>&1 | sed 's/^/  /'

# --- 10f. The poster names ----------------------------------------------
# The posts, the topics and the forums hold the name of the poster, so
# that the board can show a post without a join. The names are taken
# from the member rows.
#
# This has to run after the naming step, because a member that has
# just been given its name still carries the placeholder name in the
# posts it wrote. Without this, 3,871 posts and 3,450 topics would
# still say "Former member N".
log "recomputing the poster names"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_posts p
    JOIN ${DB_NAME}.phpbb_users u ON u.user_id = p.poster_id
    SET p.post_username = u.username
    WHERE p.post_username <> u.username AND u.username <> '';

    UPDATE ${DB_NAME}.phpbb_topics t
    JOIN ${DB_NAME}.phpbb_posts p ON p.post_id = t.topic_first_post_id
    LEFT JOIN ${DB_NAME}.phpbb_users u ON u.user_id = p.poster_id
    SET t.topic_first_poster_name = p.post_username,
        t.topic_first_poster_colour = COALESCE(u.user_colour, '');

    UPDATE ${DB_NAME}.phpbb_topics t
    JOIN ${DB_NAME}.phpbb_posts p ON p.post_id = t.topic_last_post_id
    LEFT JOIN ${DB_NAME}.phpbb_users u ON u.user_id = p.poster_id
    SET t.topic_last_poster_name = p.post_username,
        t.topic_last_poster_id = p.poster_id,
        t.topic_last_poster_colour = COALESCE(u.user_colour, ''),
        t.topic_last_post_subject = p.post_subject,
        t.topic_last_post_time = p.post_time;

    UPDATE ${DB_NAME}.phpbb_forums f
    JOIN ${DB_NAME}.phpbb_posts p ON p.post_id = f.forum_last_post_id
    SET f.forum_last_post_subject = p.post_subject,
        f.forum_last_poster_id = p.poster_id,
        f.forum_last_poster_name = p.post_username,
        f.forum_last_post_time = p.post_time;
" 2>/dev/null

STALE=$(docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e "
    SELECT COUNT(*)
    FROM ${DB_NAME}.phpbb_posts p
    JOIN ${DB_NAME}.phpbb_users u ON u.user_id = p.poster_id
    WHERE p.post_username <> u.username AND u.username <> '';
" 2>/dev/null)
log "  the posts whose name does not match the member: ${STALE}"

# --- 10g. The titles of the topics that were dropped ------------------
# The 2016 damage took the posts out of 1,162 topics and left the
# topic rows. The topics were dropped, because a topic without a post
# cannot be opened and was a dead link.
#
# The titles of those topics are not lost. They are in the recovered
# 2016 topics, and they are the record of what the forum was about.
# They are written to a table of their own, which phpBB does not
# read, so the record survives without the forum showing a topic
# that cannot be opened.
log "keeping the titles of the topics that were dropped"
python3 "${REPO_ROOT}/scripts/restore-dropped-topic-titles.py" 2>&1 | sed 's/^/  /'

# The first and last post pointers of the topics and the forums point
# at posts that are not there. They are taken from the posts that are.
#
# A topic that is in a forum that does not exist cannot be opened
# either. The 2013 dump lost the forum of one announcement, and it
# belongs in the Site Discussion Room.
log "repairing the first and last post pointers"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_topics t
    SET t.topic_first_post_id = (
            SELECT MIN(p.post_id) FROM ${DB_NAME}.phpbb_posts p
            WHERE p.topic_id = t.topic_id
        ),
        t.topic_last_post_id = (
            SELECT MAX(p.post_id) FROM ${DB_NAME}.phpbb_posts p
            WHERE p.topic_id = t.topic_id
        )
    WHERE (t.topic_first_post_id > 0
           AND t.topic_first_post_id NOT IN (SELECT post_id FROM ${DB_NAME}.phpbb_posts))
       OR (t.topic_last_post_id > 0
           AND t.topic_last_post_id NOT IN (SELECT post_id FROM ${DB_NAME}.phpbb_posts));

    UPDATE ${DB_NAME}.phpbb_forums f
    JOIN (SELECT forum_id, MAX(post_id) AS lp
          FROM ${DB_NAME}.phpbb_posts WHERE post_visibility = 1
          GROUP BY forum_id) l ON l.forum_id = f.forum_id
    SET f.forum_last_post_id = l.lp
    WHERE f.forum_last_post_id <> l.lp;

    UPDATE ${DB_NAME}.phpbb_topics SET forum_id = 37 WHERE forum_id = 0;
    UPDATE ${DB_NAME}.phpbb_posts SET forum_id = 37 WHERE forum_id = 0;
" 2>/dev/null

# --- 11. The board counters ---------------------------------------------
# The board index shows the number of posts, topics and members from
# the phpbb_config table. The values are the ones the old forum had,
# and they do not match the recovered data, so the statistics on the
# board index are wrong.
#
# The member count excludes the bots, because phpBB does not count
# them either.
log "recomputing the board counters"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_config
    SET config_value = (SELECT COUNT(*) FROM ${DB_NAME}.phpbb_users
                        WHERE user_type IN (0, 3))
    WHERE config_name = 'num_users';

    UPDATE ${DB_NAME}.phpbb_config
    SET config_value = (SELECT COUNT(*) FROM ${DB_NAME}.phpbb_posts
                        WHERE post_visibility = 1)
    WHERE config_name = 'num_posts';

    UPDATE ${DB_NAME}.phpbb_config
    SET config_value = (SELECT COUNT(*) FROM ${DB_NAME}.phpbb_topics)
    WHERE config_name = 'num_topics';
" 2>/dev/null

docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e "
    SELECT CONCAT('  ', config_name, ' = ', config_value)
    FROM ${DB_NAME}.phpbb_config
    WHERE config_name IN ('num_users', 'num_posts', 'num_topics');
" 2>/dev/null | sed 's/^/  /'

# --- 12. The forum lock --------------------------------------------------
# The forum is read only for the time being. Nothing can be posted
# and nothing can be replied to, so the old threads stay as they
# are.
#
# The forums are locked with forum_status, which is what the
# administration panel sets. A locked forum is read only for
# everybody without the m_lock permission, and that is the
# administrators and the moderators. They can still post, so the
# staff can tidy up the board.
#
# The topics that are already locked stay locked. The unlocked
# topics are not locked, because a member cannot start a topic in a
# locked forum anyway, and the old topics read better when they can
# be replied to by the staff.
log "locking the forums"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_forums
    SET forum_status = 1
    WHERE forum_type = 1 AND forum_status <> 1;
" 2>/dev/null

docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e "
    SELECT CONCAT('  ', forum_type, ' | ', COUNT(*), ' forums | ', SUM(forum_status = 1), ' locked')
    FROM ${DB_NAME}.phpbb_forums
    GROUP BY forum_type;
" 2>/dev/null | sed 's/^/  /'

# --- 13. The founder -----------------------------------------------------
# The founder is the member that holds every administration
# permission. The name is the one the board's administrator used, and
# it comes from the environment.
#
# phpBB grants those permissions from the user_type column, not from
# the group. A member with user_type = 3 (USER_FOUNDER) is given
# every a_* option at login, whatever the group says. The recovered
# board has no founder, so the administrators group has to carry
# every permission by hand, and it carries only seven of the
# forty-five.
#
# The result is an administration panel with four tabs instead of
# nine, and a 503 on most of the pages behind them.
#
# The founder also has a cached permission bitstring in
# user_permissions. phpBB only rebuilds that bitstring when it is
# empty, so it is cleared here as well. Otherwise the founder flag
# is set but the old permissions are kept.
log "making ${FOUNDER_USERNAME} the founder of the board"
docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -e "
    UPDATE ${DB_NAME}.phpbb_users
    SET user_type = 3,
        user_permissions = ''
    WHERE username = '${FOUNDER_USERNAME}';
" 2>/dev/null

docker exec "${CONTAINER}" mariadb -u"${DB_USER}" "-p${DB_PASS}" -N -e "
    SELECT CONCAT('  ', user_id, ' | ', username, ' | user_type = ', user_type)
    FROM ${DB_NAME}.phpbb_users
    WHERE user_type = 3;
" 2>/dev/null | sed 's/^/  /'

# --- 14. The administration panel module tree ---------------------------
# The recovered module tree has two faults.
#
# The first is the module rows that belong to extensions that are
# not installed. Clicking them gives a 503, because phpBB looks for
# a PHP file that is not on disk.
#
# The second is the left_id and right_id values. The old extensions
# were inserted with values that other rows already use, so ten
# values are used twice, and five rows sit outside the range of
# their parent. phpBB reads the tree with a nested set query, so the
# collisions make the tree unreadable.
#
# The AutoGroups module row is kept. The extension is not installed,
# so the row is inert, but its configuration is being kept, and the
# row comes back with the extension.
log "repairing the administration panel module tree"
docker cp "${REPO_ROOT}/scripts/repair-acp-modules.php" \
    "$(docker compose ps -q phpbb 2>/dev/null | head -1):/tmp/repair-acp-modules.php" 2>/dev/null \
    || true

docker compose exec -T phpbb php /tmp/repair-acp-modules.php 2>&1 \
    | sed 's/^/  /' || true

# --- 15. The cache ------------------------------------------------------
# The module cache holds a copy of the module tree, so it is cleared
# after the tree is repaired. This is the same cache clear as step 5.
log "clearing the forum cache"
docker compose exec -T phpbb sh -c \
    'rm -f /var/www/html/cache/production/data_*.php /var/www/html/cache/production/data_*.php.lock' \
    2>/dev/null || true

# --- 16. The bot accounts -----------------------------------------------
# The recovered bots are in the wrong shape.
#
# A stock phpBB bot member has the type USER_IGNORE, the group_id of
# the BOTS group and the user_colour of the BOTS group, and an empty
# password, an empty email and no ip.
#
# The recovered bots were recreated as members, so they have the
# default colour 000000 and the default group. They are in the BOTS
# group through their phpbb_user_group rows, so they show in the
# member list, but they render in the wrong colour.
#
# The phpBB 3.3 migration that creates the bots cannot fix this,
# because it SKIPS a bot whose name already exists:
#
#     if ($bot_exists) { continue; }
#
# So the recovered data has to be put into the shape the stock board
# uses. The script also creates the 8 stock bots whose member rows
# were destroyed, which the migration skipped for the same reason.
log "repairing the bot accounts"
docker cp "${REPO_ROOT}/scripts/fix-bot-accounts.php" \
    "$(docker compose ps -q phpbb 2>/dev/null | head -1):/tmp/fix-bot-accounts.php" 2>/dev/null \
    || true

docker compose exec -T phpbb php /tmp/fix-bot-accounts.php 2>&1 \
    | sed 's/^/  /' || true

docker cp "${REPO_ROOT}/scripts/restore-missing-bot-accounts.php" \
    "$(docker compose ps -q phpbb 2>/dev/null | head -1):/tmp/restore-missing-bot-accounts.php" 2>/dev/null \
    || true

docker compose exec -T phpbb php /tmp/restore-missing-bot-accounts.php 2>&1 \
    | sed 's/^/  /' || true

# --- 17. The system cron --------------------------------------------------
# The board runs its scheduled tasks from a Kubernetes CronJob, so
# phpBB must not run them itself.
#
# phpBB runs the tasks opportunistically. When a visitor loads a
# page and a task is ready, phpBB puts a hidden image tag in the page
# and the browser fetches it, which runs the task:
#
#   <img class="sr-only" aria-hidden="true"
#        src="/forum/cron/cron.task.text_reparser.post_text?sid=...">
#
# The URL is under /forum/cron/, which Cloudflare blocks, so every
# visitor got a 403 in their console. The tag also runs the task a
# second time, which the CronJob has already done.
#
# The setting that stops it is use_system_cron. The ACP calls it
# "Run periodic tasks from operating system cron".
log "configuring the board for the system cron"
docker cp "${REPO_ROOT}/scripts/configure-system-cron.php" \
    "$(docker compose ps -q phpbb 2>/dev/null | head -1):/tmp/configure-system-cron.php" 2>/dev/null \
    || true

docker compose exec -T phpbb php /tmp/configure-system-cron.php 2>&1 \
    | sed 's/^/  /' || true

log "the repair is done"

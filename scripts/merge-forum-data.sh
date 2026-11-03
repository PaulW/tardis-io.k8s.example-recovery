#!/bin/bash
# =====================================================================
# Merge the 2013 dump into the 2016/2017 recovery.
# =====================================================================
# The two sources are complementary, not overlapping:
#
#   2013 dump (phpMyAdmin, 13 Sep 2013)
#     - 124,200 posts, complete and intact
#     - 47 forums, 11,794 private messages, board settings
#     - TRUNCATED during phpbb_sessions_keys, so it has NO phpbb_users,
#       NO phpbb_topics and none of the tables that sort after it
#
#   2016/2017 recovery (raw MySQL data directory)
#     - 2,176 users, 3,835 topics, 1,421 posts, plus the custom
#       "garage" and "ads" mods
#     - the posts/users/topics tables were mostly destroyed
#
# Merged result:
#   - 125,621 posts
#   - ~15,000 topics (3,835 recovered + ~11,000 rebuilt)
#   - 2,176 users (the only copy that exists)
#
# The rebuild works because phpBB stores the topic title in the FIRST
# post's post_subject as well as in phpbb_topics.topic_title. Verified
# against the topics that survived: 2,529 of 2,531 match exactly.
#
# Usage:
#   ./scripts/merge-forum-data.sh
# =====================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECOVERED="${REPO_ROOT}/backup_recover/recovered"
DUMP_2013="${REPO_ROOT}/backup_recover/phpbb.sql"
CONTAINER="phpbb-mariadb"
DB_2013="phpbb_2013"
DB_TARGET="phpbb"
ROOT_PASS="${MARIADB_ROOT_PASSWORD:-root_secret_password}"

log() { echo "[merge] $*"; }
die() { echo "[merge] ERROR: $*" >&2; exit 1; }

[ -f "${DUMP_2013}" ] || die "2013 dump not found: ${DUMP_2013}"
[ -f "${RECOVERED}/phpbb_data.sql" ] \
    || die "no recovered data. Run scripts/recover-forum-db.sh first."

docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$" \
    || die "MariaDB container ${CONTAINER} is not running"

Q() { docker exec "${CONTAINER}" mariadb -uroot "-p${ROOT_PASS}" -N -e "$1" 2>/dev/null; }

# --- Load the 2013 dump into its own database --------------------------
log "loading the 2013 dump into ${DB_2013}"
Q "DROP DATABASE IF EXISTS ${DB_2013};" >/dev/null
Q "CREATE DATABASE ${DB_2013} DEFAULT CHARACTER SET utf8;" >/dev/null
docker exec -i "${CONTAINER}" mariadb -uroot "-p${ROOT_PASS}" "${DB_2013}" \
    < "${DUMP_2013}" 2>/dev/null || true
POSTS_2013=$(Q "SELECT COUNT(*) FROM ${DB_2013}.phpbb_posts;" | head -1)
log "  loaded ${POSTS_2013} posts from 2013"

# --- Forums ---------------------------------------------------------------
# The 2013 dump has 47 forums, the 2016 recovery has 43. Five forums
# exist only in 2013 and hold 184 posts, and one exists only in 2016.
# Merge them so no post references a forum that does not exist.
#
# The column sets differ: 2013 has forum_posts/forum_topics/
# forum_topics_real, 2016 has the approved/unapproved/softdeleted
# split. The common columns are copied, and the counters are
# recomputed from the merged posts further down.
log "merging phpbb_forums"
FORUM_COMMON=$(Q "SELECT GROUP_CONCAT(a.COLUMN_NAME ORDER BY a.ORDINAL_POSITION)
                   FROM information_schema.COLUMNS a
                   JOIN information_schema.COLUMNS b
                     ON b.COLUMN_NAME = a.COLUMN_NAME
                    AND b.TABLE_SCHEMA='${DB_TARGET}'
                    AND b.TABLE_NAME='phpbb_forums'
                   WHERE a.TABLE_SCHEMA='${DB_2013}' AND a.TABLE_NAME='phpbb_forums';" | head -1)
FORUM_SEL=$(echo "${FORUM_COMMON}" | sed 's/\([^, ]*\)/s.\1/g')
Q "SET SESSION sql_mode='';
   INSERT INTO ${DB_TARGET}.phpbb_forums (${FORUM_COMMON})
   SELECT ${FORUM_SEL} FROM ${DB_2013}.phpbb_forums s
   WHERE NOT EXISTS (
       SELECT 1 FROM ${DB_TARGET}.phpbb_forums t
       WHERE t.forum_id = s.forum_id
   );" >/dev/null 2>&1 || log "  forum copy failed"
log "  forums merged"

# --- Recreate the unrecoverable tables -----------------------------------
# 11 tables in the 2016 backup were too damaged to repair, so they are
# absent from BOTH sources:
#   phpbb_ext, phpbb_migrations, phpbb_notifications,
#   phpbb_notification_types, phpbb_oauth_accounts, phpbb_oauth_tokens,
#   phpbb_config_text, phpbb_user_notifications,
#   phpbb_autogroups_rules, phpbb_autogroups_types
#
# They are recreated from phpBB's own schema, which the installer
# image ships as install/schemas/schema.json. The last two are 3.1-only
# extension tables and are not referenced by 3.3.x.
log "recreating the tables that could not be recovered"
MISSING_SQL="${REPO_ROOT}/backup_recover/recovered/missing-tables.sql"
if [ -f "${MISSING_SQL}" ]; then
    docker exec -i "${CONTAINER}" mariadb -uroot "-p${ROOT_PASS}" "${DB_TARGET}" \
        < "${MISSING_SQL}" 2>/dev/null || true
    log "  recreated"
else
    log "  ${MISSING_SQL} not found, skipping"
fi

# --- Posts -------------------------------------------------------------
# The 2013 posts have post_approved; the 2016 posts have the soft
# delete columns. Map between them.
log "merging phpbb_posts"
Q "
SET SESSION sql_mode='';
INSERT INTO ${DB_TARGET}.phpbb_posts (
    post_id, topic_id, forum_id, poster_id, icon_id, poster_ip,
    post_time, post_reported, enable_bbcode, enable_smilies,
    enable_magic_url, enable_sig, post_username, post_subject,
    post_text, post_checksum, post_attachment, bbcode_bitfield,
    bbcode_uid, post_postcount, post_edit_time, post_edit_reason,
    post_edit_user, post_edit_count, post_edit_locked,
    post_visibility, post_delete_time, post_delete_reason,
    post_delete_user
)
SELECT
    p.post_id, p.topic_id, p.forum_id, p.poster_id, p.icon_id,
    p.poster_ip, p.post_time, p.post_reported, p.enable_bbcode,
    p.enable_smilies, p.enable_magic_url, p.enable_sig,
    p.post_username, p.post_subject, p.post_text, p.post_checksum,
    p.post_attachment, p.bbcode_bitfield, p.bbcode_uid,
    p.post_postcount, p.post_edit_time, p.post_edit_reason,
    p.post_edit_user, p.post_edit_count, p.post_edit_locked,
    -- post_approved in 2013 maps to post_visibility in 3.3.
    -- phpBB 3.3 uses ITEM_APPROVED = 1, ITEM_UNAPPROVED = 0,
    -- ITEM_DELETED = 2 and ITEM_REAPPROVE = 3.
    CASE WHEN p.post_approved = 1 THEN 1 ELSE 0 END,
    0, '', 0
FROM ${DB_2013}.phpbb_posts p
WHERE p.post_id NOT IN (SELECT post_id FROM ${DB_TARGET}.phpbb_posts);
" >/dev/null
log "  2013 posts inserted"

# --- Correct the visibility of the 2016 posts --------------------------
# The 2016 backup used the opposite convention. In the 2016 schema,
# post_visibility = 0 meant a visible post and 1 meant an unapproved
# one. phpBB 3.3 uses ITEM_APPROVED = 1 and ITEM_UNAPPROVED = 0, so
# the 2016 posts that were loaded into the target database have their
# visibility the wrong way round.
#
# The posts that came from the 2013 dump have the right values,
# because the insert above maps them. So only the posts that are
# unique to the 2016 backup need the values swapped.
#
# Without this, 1,421 posts from 2015 and 2016 are hidden, and the
# 146 topics that hold only those posts cannot be opened at all.
log "correcting the post visibility of the 2016 posts"
Q "
UPDATE ${DB_TARGET}.phpbb_posts
SET post_visibility = 1 - post_visibility
WHERE post_visibility IN (0, 1)
  AND post_id NOT IN (SELECT post_id FROM ${DB_2013}.phpbb_posts);
" >/dev/null
log "  the 2016 posts corrected"
# --- Load the users recovered from the index ---------------------------
# The 2016 backup's phpbb_users.MYD was destroyed, but the .MYI index
# survived. A MyISAM index stores the key value, not just a pointer to
# the row, so the username of every member is still there, and the
# PRIMARY index holds the user_id.
#
# The recovery script reads the index and writes the pairs out. This
# step loads them, so the posts are not attributed to "Unknown".
log "loading the users recovered from the MyISAM index"
RECOVERED_USERS="${REPO_ROOT}/backup_recover/recovered/recovered-users.tsv"
if [ -f "${RECOVERED_USERS}" ]; then
    MARIADB_CONTAINER="${CONTAINER}" PHPBB_DB_NAME="${DB_TARGET}" \
        MARIADB_ROOT_PASSWORD="${ROOT_PASS}" \
        python3 "${REPO_ROOT}/scripts/load-recovered-users.py" \
            "${RECOVERED_USERS}" 2>&1 | sed 's/^/  /' || true
else
    log "  ${RECOVERED_USERS} not found, skipping"
fi

# --- Load the rows recovered from the data files -----------------------
# The phpbb_log and phpbb_privmsgs data files each have a hole. The
# repair truncates the file at the hole, so the rows on either side of
# it are lost. The recovery closes the hole and reads the rows back.
# This step loads the rows that the merged database does not have.
log "loading the rows recovered from the data files"
RECOVERED_TABLES="${REPO_ROOT}/backup_recover/recovered/recovered-tables"
if [ -d "${RECOVERED_TABLES}" ]; then
    MARIADB_CONTAINER="${CONTAINER}" PHPBB_DB_NAME="${DB_TARGET}" \
        MARIADB_ROOT_PASSWORD="${ROOT_PASS}" \
        python3 "${REPO_ROOT}/scripts/load-recovered-tables.py" \
            "${RECOVERED_TABLES}" "${DB_TARGET}" 2>&1 | sed 's/^/  /' || true
else
    log "  ${RECOVERED_TABLES} not found, skipping"
fi

# --- Rebuild the missing topics ----------------------------------------
# The 2013 posts reference 15,090 topics. The 2016 recovery only has
# 3,835 topic rows. Rebuild the rest from the posts.
log "rebuilding phpbb_topics from the 2013 posts"
Q "
SET SESSION sql_mode='';
INSERT INTO ${DB_TARGET}.phpbb_topics (
    topic_id, forum_id, topic_title, topic_poster, topic_time,
    topic_views, topic_status, topic_type,
    topic_first_post_id, topic_first_poster_name,
    topic_last_post_id, topic_last_post_subject,
    topic_last_post_time, topic_last_view_time,
    topic_moved_id, topic_bumped, topic_bumper,
    topic_time_limit, topic_attachment, topic_reported,
    poll_title, poll_start, poll_length, poll_max_options,
    poll_last_vote, poll_vote_change,
    topic_visibility, topic_delete_time, topic_delete_reason,
    topic_delete_user,
    topic_posts_approved, topic_posts_unapproved, topic_posts_softdeleted
)
SELECT
    f.topic_id, f.forum_id, f.post_subject, f.poster_id, f.post_time,
    0, 1, 0,
    f.post_id, f.post_username,
    l.post_id, l.post_subject, l.post_time, l.post_time,
    0, 0, '', 0, 0, 0, '', 0, 0, 0, 0, 0, 1, 0, '', 0,
    COALESCE(c.post_count, 0), 0, 0
FROM (
    SELECT pp.topic_id, pp.forum_id, pp.post_id, pp.poster_id,
           pp.post_time, pp.post_subject, pp.post_username
    FROM ${DB_TARGET}.phpbb_posts pp
    JOIN (SELECT topic_id, MIN(post_id) AS f
          FROM ${DB_TARGET}.phpbb_posts GROUP BY topic_id) x
      ON x.f = pp.post_id
) f
JOIN (
    SELECT pp.topic_id, pp.post_id, pp.post_subject, pp.post_time
    FROM ${DB_TARGET}.phpbb_posts pp
    JOIN (SELECT topic_id, MAX(post_id) AS l
          FROM ${DB_TARGET}.phpbb_posts GROUP BY topic_id) y
      ON y.l = pp.post_id
) l ON l.topic_id = f.topic_id
LEFT JOIN (
    -- Count every post, not just the approved ones. A topic whose
    -- posts are all unapproved would otherwise get no row here, and
    -- the INNER JOIN would drop the topic, leaving its posts
    -- orphaned.
    SELECT topic_id, COUNT(*) AS post_count
    FROM ${DB_TARGET}.phpbb_posts GROUP BY topic_id
) c ON c.topic_id = f.topic_id
WHERE NOT EXISTS (
    SELECT 1 FROM ${DB_TARGET}.phpbb_topics t
    WHERE t.topic_id = f.topic_id
);
" >/dev/null
log "  topics rebuilt"

# --- Forum counters ----------------------------------------------------
# The 2016 forums table has the approved/unapproved/softdeleted split.
# Recompute them from the merged posts and topics.
# Recompute the counters AFTER the topics are rebuilt, so the counts
# reflect the merged data.
log "recomputing the forum post and topic counters"
# The 2013 dump had no soft-delete column, so every post it held was
# an approved post. phpBB 3.3 uses post_visibility = 1 for an
# approved post (ITEM_APPROVED) and 0 for an unapproved one
# (ITEM_UNAPPROVED). Count on that basis so the forum counters match
# the rows that are actually there.
Q "
UPDATE ${DB_TARGET}.phpbb_forums f
LEFT JOIN (
    SELECT forum_id, COUNT(*) AS c
    FROM ${DB_TARGET}.phpbb_posts
    WHERE post_visibility = 1
    GROUP BY forum_id
) p ON p.forum_id = f.forum_id
LEFT JOIN (
    SELECT forum_id, COUNT(*) AS c
    FROM ${DB_TARGET}.phpbb_posts
    WHERE post_visibility = 0
    GROUP BY forum_id
) pu ON pu.forum_id = f.forum_id
LEFT JOIN (
    SELECT forum_id, COUNT(*) AS c
    FROM ${DB_TARGET}.phpbb_topics
    WHERE topic_visibility = 1
    GROUP BY forum_id
) t ON t.forum_id = f.forum_id
LEFT JOIN (
    SELECT forum_id, COUNT(*) AS c
    FROM ${DB_TARGET}.phpbb_topics
    WHERE topic_visibility = 0
    GROUP BY forum_id
) tu ON tu.forum_id = f.forum_id
SET f.forum_posts_approved     = COALESCE(p.c, 0),
    f.forum_topics_approved    = COALESCE(t.c, 0),
    f.forum_posts_unapproved   = COALESCE(pu.c, 0),
    f.forum_topics_unapproved  = COALESCE(tu.c, 0),
    f.forum_posts_softdeleted  = 0,
    f.forum_topics_softdeleted = 0;
" >/dev/null

# --- Other tables -------------------------------------------------------
# Copy the 2013 data for the tables that are identical in both schemas
# and that hold real content. Each table is listed with its primary
# key so the copy skips rows that already exist.
log "copying the remaining common tables from 2013"
copy_table() {
    local table="$1"
    # Work out the key from the table itself, so the copy does not
    # depend on a hand-maintained list that can drift.
    #
    # Prefer the primary key, then any unique key. If the table has
    # neither, use all of its columns as the key, which is correct for
    # the phpBB link tables (they have composite keys but no unique
    # index).
    local key
    key=$(Q "SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE
              WHERE TABLE_SCHEMA='${DB_2013}' AND TABLE_NAME='${table}'
                AND CONSTRAINT_NAME='PRIMARY' LIMIT 1;" | head -1)
    if [ -z "${key}" ]; then
        key=$(Q "SELECT COLUMN_NAME FROM information_schema.STATISTICS
                  WHERE TABLE_SCHEMA='${DB_2013}' AND TABLE_NAME='${table}'
                    AND NON_UNIQUE=0 AND SEQ_IN_INDEX=1 LIMIT 1;" | head -1)
    fi
    if [ -z "${key}" ]; then
        # No unique index: key on every column. The key expression
        # pairs each target column with its source column, so build
        # the two lists separately and join them.
        local cols
        cols=$(Q "SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY ORDINAL_POSITION)
                    FROM information_schema.COLUMNS
                    WHERE TABLE_SCHEMA='${DB_2013}' AND TABLE_NAME='${table}';" | head -1)
        if [ -z "${cols}" ]; then
            log "  skip ${table}: cannot work out a key"
            return 0
        fi
        local i=1
        local expr=""
        local c
        for c in $(echo "${cols}" | tr ',' ' '); do
            [ -n "${expr}" ] && expr="${expr} AND "
            expr="${expr}t.${c} = s.${c}"
            i=$((i + 1))
        done
        key="${expr}"
        # The column list may differ between the two schemas. Copy the
        # columns that exist in BOTH, and let the rest default.
        local common
        common=$(Q "SELECT GROUP_CONCAT(a.COLUMN_NAME ORDER BY a.ORDINAL_POSITION)
                     FROM information_schema.COLUMNS a
                     JOIN information_schema.COLUMNS b
                       ON b.COLUMN_NAME = a.COLUMN_NAME
                      AND b.TABLE_SCHEMA='${DB_TARGET}'
                      AND b.TABLE_NAME='${table}'
                     WHERE a.TABLE_SCHEMA='${DB_2013}' AND a.TABLE_NAME='${table}';" | head -1)
        if [ -z "${common}" ]; then
            log "  skip ${table}: no common columns"
            return 0
        fi
        local sel
        sel=$(echo "${common}" | sed 's/\([^, ]*\)/s.\1/g')
        Q "SET SESSION sql_mode='';
           INSERT INTO ${DB_TARGET}.${table} (${common})
           SELECT ${sel} FROM ${DB_2013}.${table} s
           WHERE NOT EXISTS (
               SELECT 1 FROM ${DB_TARGET}.${table} t
               WHERE ${key}
           );" >/dev/null 2>&1 || log "  ${table}: copy failed"
        return 0
    fi

    # The 2016 schema may have extra columns. Copy only the columns
    # that exist in both, so the remaining ones take their defaults.
    local common
    common=$(Q "SELECT GROUP_CONCAT(a.COLUMN_NAME ORDER BY a.ORDINAL_POSITION)
                 FROM information_schema.COLUMNS a
                 JOIN information_schema.COLUMNS b
                   ON b.COLUMN_NAME = a.COLUMN_NAME
                  AND b.TABLE_SCHEMA='${DB_TARGET}'
                  AND b.TABLE_NAME='${table}'
                 WHERE a.TABLE_SCHEMA='${DB_2013}' AND a.TABLE_NAME='${table}';" | head -1)
    if [ -z "${common}" ]; then
        log "  skip ${table}: no common columns"
        return 0
    fi
    local sel
    sel=$(echo "${common}" | sed 's/\([^, ]*\)/s.\1/g')
    Q "SET SESSION sql_mode='';
       INSERT INTO ${DB_TARGET}.${table} (${common})
       SELECT ${sel} FROM ${DB_2013}.${table} s
       WHERE NOT EXISTS (
           SELECT 1 FROM ${DB_TARGET}.${table} t
           WHERE t.${key} = s.${key}
       );" >/dev/null 2>&1 || log "  ${table}: copy failed"
}

for t in phpbb_privmsgs phpbb_privmsgs_to phpbb_privmsgs_folder \
         phpbb_log phpbb_forums_track phpbb_forums_watch \
         phpbb_profile_fields_data phpbb_bots phpbb_banlist \
         phpbb_drafts phpbb_acl_roles_data phpbb_acl_groups \
         phpbb_acl_options phpbb_acl_users phpbb_acl_roles \
         phpbb_extension_groups phpbb_extensions phpbb_modules \
         phpbb_poll_options phpbb_poll_votes phpbb_profile_fields_lang \
         phpbb_profile_lang phpbb_ranks phpbb_groups \
         phpbb_bookmarks phpbb_moderator_cache phpbb_reports \
         phpbb_reports_reasons phpbb_qa_confirm phpbb_icons \
         phpbb_ads phpbb_ads_positions phpbb_ads_in_positions; do
    copy_table "${t}"
done

# --- Report -------------------------------------------------------------
log ""
log "=== merged result ==="
for t in phpbb_users phpbb_topics phpbb_posts phpbb_forums phpbb_config phpbb_privmsgs; do
    n=$(Q "SELECT COUNT(*) FROM ${DB_TARGET}.${t};" | head -1)
    printf '  %-24s %s\n' "${t}" "${n}"
done

log ""
log "=== integrity checks ==="
ORPHAN_POSTS=$(Q "SELECT COUNT(*) FROM ${DB_TARGET}.phpbb_posts p
                  WHERE NOT EXISTS (SELECT 1 FROM ${DB_TARGET}.phpbb_topics t
                                    WHERE t.topic_id = p.topic_id);" | head -1)
log "  posts with no topic row : ${ORPHAN_POSTS}"

ORPHAN_TOPICS=$(Q "SELECT COUNT(*) FROM ${DB_TARGET}.phpbb_topics t
                   WHERE NOT EXISTS (SELECT 1 FROM ${DB_TARGET}.phpbb_posts p
                                     WHERE p.topic_id = t.topic_id);" | head -1)
log "  topics with no post row : ${ORPHAN_TOPICS}"

log ""
log "done. The merged database is '${DB_TARGET}'."

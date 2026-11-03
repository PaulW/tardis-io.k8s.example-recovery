<?php
/**
 * Restore the admin and moderator designations of the forum.
 *
 * The forum does not show its staff, because three things were lost.
 *
 * 1. The DEFAULT GROUP. phpBB shows a member's rank and colour from
 *    the group named in phpbb_users.group_id, not from the groups
 *    the member belongs to. The 3.3 migration reset every default
 *    group to REGISTERED, so the administrators lost the
 *    ADMINISTRATORS default and the moderators lost theirs. A
 *    member of the ADMINISTRATORS group with a REGISTERED default
 *    is an admin in the control panel, but reads as an ordinary
 *    member under their own name.
 *
 * 2. The RANK AND COLOUR of the members whose user row was
 *    destroyed. The row was rebuilt from the index, which only holds
 *    the name and the id, so the rank and the colour were left at
 *    zero and black.
 *
 * 3. The NAME of some of those members. The index recovery kept the
 *    name, but not for everyone. The 2013 database still holds the
 *    original name in its own caches: the forum table keeps the
 *    name of the last poster of every forum, and the moderator
 *    cache keeps the name of every moderator.
 *
 * The script restores all three, and then rebuilds the moderator
 * cache with phpBB's own function, so the forum pages list the
 * moderators again.
 *
 * The script runs inside the phpbb container, which has the PHP 8
 * compatible dependencies that the phpBB 3.3.19 release needs.
 *
 * Usage:
 *   php restore-staff-roles.php [--dry-run]
 */

if (php_sapi_name() !== 'cli') {
    exit(1);
}

define('IN_PHPBB', true);
define('PHPBB_ENVIRONMENT', 'production');
$phpbb_root_path = '/var/www/html/';
$phpEx = 'php';

require($phpbb_root_path . 'common.' . $phpEx);
require($phpbb_root_path . 'includes/functions_admin.' . $phpEx);
require($phpbb_root_path . 'includes/functions_user.' . $phpEx);

global $db, $table_prefix, $auth, $cache;

$dry_run = in_array('--dry-run', $argv, true);

$source_db = getenv('PHPBB_SOURCE_DB');
if (!$source_db) {
    $source_db = 'phpbb_2013';
}
$source_host = getenv('PHPBB_DB_HOST');
if (!$source_host) {
    $source_host = 'mariadb';
}
$source_user = getenv('MARIADB_ROOT_USER');
if (!$source_user) {
    $source_user = 'root';
}
$source_pass = getenv('MARIADB_ROOT_PASSWORD');
if (!$source_pass) {
    $source_pass = 'root_secret_password';
}

/**
 * The groups that carry a rank, a colour, or a permission.
 *
 * The rank is what a reader sees under the name. The colour is what
 * makes the name stand out. The permission is what lets the member
 * moderate the forum.
 */
$staff_groups = array(4, 5, 9, 10, 11, 12, 13, 14, 15);

echo "  the staff groups:\n";
$sql = 'SELECT group_id, group_name, group_rank, group_colour
        FROM ' . $table_prefix . 'groups
        WHERE group_id IN (' . implode(',', $staff_groups) . ')
        ORDER BY group_id';
$result = $db->sql_query($sql);
$groups = $db->sql_fetchrowset($result);
$db->sql_freeresult($result);

$group_rank = array();
$group_colour = array();
foreach ($groups as $group) {
    $group_rank[$group['group_id']] = (int) $group['group_rank'];
    $group_colour[$group['group_id']] = $group['group_colour'];
    echo '    ' . $group['group_id'] . '  ' . $group['group_name']
        . '  rank=' . $group['group_rank']
        . '  colour=' . $group['group_colour'] . "\n";
}

/**
 * The members of the staff groups, and the group each one should
 * use as their default.
 *
 * The default group is the one that carries the rank and the
 * colour. Where a member belongs to more than one staff group, the
 * group with the highest rank wins, because that is the group the
 * forum used for them: an administrator who is also a moderator is
 * shown as an administrator.
 */
$sql = 'SELECT ug.user_id, ug.group_id, u.username, u.user_type,
               u.user_rank, u.user_colour
        FROM ' . $table_prefix . 'user_group ug
        JOIN ' . $table_prefix . 'users u ON u.user_id = ug.user_id
        WHERE ug.group_id IN (' . implode(',', $staff_groups) . ')
          AND ug.user_pending = 0
        ORDER BY ug.user_id, ug.group_id';
$result = $db->sql_query($sql);
$rows = $db->sql_fetchrowset($result);
$db->sql_freeresult($result);

$members = array();
foreach ($rows as $row) {
    $uid = (int) $row['user_id'];
    $gid = (int) $row['group_id'];

    if (!isset($members[$uid])) {
        $members[$uid] = array(
            'username'   => $row['username'],
            'user_type'  => (int) $row['user_type'],
            'rank'       => (int) $row['user_rank'],
            'colour'     => $row['user_colour'],
            'groups'     => array(),
            'best_group' => 0,
        );
    }
    $members[$uid]['groups'][] = $gid;

    // The group with the highest rank is the one to use as the
    // default, so that an administrator who also moderates is shown
    // as an administrator.
    if (!isset($group_rank[$gid])) {
        continue;
    }
    if (!$members[$uid]['best_group']
        || $group_rank[$gid] > $group_rank[$members[$uid]['best_group']]
        || ($group_rank[$gid] == $group_rank[$members[$uid]['best_group']]
            && $gid < $members[$uid]['best_group'])) {
        $members[$uid]['best_group'] = $gid;
    }
}

echo '  the members of a staff group: ' . count($members) . "\n";

/**
 * The original names and colours of the members, read from the 2013
 * database.
 *
 * The 2013 database still holds the name of every member in the
 * caches that phpBB writes: the forum table keeps the name of the
 * last poster of every forum, the moderator cache keeps the name of
 * every moderator, and the private messages keep the name of their
 * author. A member whose user row was destroyed keeps the name in
 * one or more of them.
 */
$originals = array();
$original_colour = array();

$source = @mysqli_connect($source_host, $source_user, $source_pass, $source_db);
if (!$source) {
    echo '  the ' . $source_db . ' database is not reachable: ' . mysqli_connect_error() . "\n";
    echo "  the names of the members whose row was destroyed cannot be restored\n";
} else {
    $name_queries = array(
        "SELECT forum_last_poster_id, forum_last_poster_name
         FROM phpbb_forums
         WHERE forum_last_poster_id > 0 AND forum_last_poster_name <> ''",
        "SELECT user_id, username
         FROM phpbb_moderator_cache
         WHERE user_id > 0 AND username <> ''",
        "SELECT author_id, author_name
         FROM phpbb_privmsgs
         WHERE author_id > 0 AND author_name <> ''",
    );

    foreach ($name_queries as $query) {
        $res = @mysqli_query($source, $query);
        if (!$res) {
            continue;
        }
        while ($row = mysqli_fetch_row($res)) {
            $uid = (int) $row[0];
            if (!$uid || $row[1] === '') {
                continue;
            }
            if (!isset($originals[$uid])) {
                $originals[$uid] = $row[1];
            }
        }
        mysqli_free_result($res);
    }

    // The colour of the last poster of a forum is the colour of
    // the group the member belonged to at the time.
    $res = @mysqli_query($source,
        "SELECT forum_last_poster_id, forum_last_poster_colour
         FROM phpbb_forums
         WHERE forum_last_poster_id > 0 AND forum_last_poster_colour <> ''");
    if ($res) {
        while ($row = mysqli_fetch_row($res)) {
            $uid = (int) $row[0];
            if ($uid && !isset($original_colour[$uid])) {
                $original_colour[$uid] = $row[1];
            }
        }
        mysqli_free_result($res);
    }
    mysqli_close($source);

    echo '  the original names found in the ' . $source_db . ' database: '
        . count($originals) . "\n";
}

/**
 * The original case of the member names.
 *
 * The index recovery read the names from the username_clean index,
 * and that column holds the lowercase name by definition in phpBB.
 * So the members whose user row was destroyed have a lowercase name,
 * and the original case has to come from the forum's own caches.
 *
 * The caches hold the name as it was written, so they hold the
 * original case. A name is only used when it matches the member's
 * current name, ignoring the case, so a member is never renamed to
 * a different member's name.
 */
$cases = array();

$case_sources = array(
    // the topic and forum rows of the live board, which the repair
    // step fills in from the member rows
    "SELECT topic_poster AS user_id, topic_first_poster_name AS username
     FROM " . $table_prefix . "topics
     WHERE topic_first_poster_name <> ''",
    "SELECT topic_last_poster_id AS user_id, topic_last_poster_name AS username
     FROM " . $table_prefix . "topics
     WHERE topic_last_poster_name <> ''",
    "SELECT forum_last_poster_id AS user_id, forum_last_poster_name AS username
     FROM " . $table_prefix . "forums
     WHERE forum_last_poster_name <> ''",
);

foreach ($case_sources as $query) {
    $result = $db->sql_query($query);
    while ($row = $db->sql_fetchrow($result)) {
        $uid = (int) $row['user_id'];
        $name = $row['username'];
        if (!$uid || $name === '') {
            continue;
        }
        if (!isset($cases[$uid]) || ($cases[$uid] == mb_strtolower($cases[$uid]) && $name != mb_strtolower($name))) {
            $cases[$uid] = $name;
        }
    }
    $db->sql_freeresult($result);
}

// the 2013 caches, which hold the names of the members the live
// caches do not cover
$source = @mysqli_connect($source_host, $source_user, $source_pass, $source_db);
if ($source) {
    $case_queries = array(
        "SELECT poster_id, post_username
         FROM phpbb_posts
         WHERE post_username <> ''",
        "SELECT forum_last_poster_id, forum_last_poster_name
         FROM phpbb_forums
         WHERE forum_last_poster_name <> ''",
        "SELECT user_id, username
         FROM phpbb_moderator_cache
         WHERE username <> ''",
    );

    foreach ($case_queries as $query) {
        $res = @mysqli_query($source, $query);
        if (!$res) {
            continue;
        }
        while ($row = mysqli_fetch_row($res)) {
            $uid = (int) $row[0];
            $name = $row[1];
            if (!$uid || $name === '') {
                continue;
            }
            if (!isset($cases[$uid]) || ($cases[$uid] == mb_strtolower($cases[$uid]) && $name != mb_strtolower($name))) {
                $cases[$uid] = $name;
            }
        }
        mysqli_free_result($res);
    }
    mysqli_close($source);
}

echo '  the member names with a known case: ' . count($cases) . "\n";

/**
 * Restore the original case of the member names.
 *
 * A member whose name is already mixed case is left alone, because
 * that is the case the forum had. A member whose name is all lower
 * case gets the case from the caches, but only when the cached name
 * is the same name, ignoring the case. That way a member is never
 * renamed to a different member's name.
 */
$sql = 'SELECT user_id, username
        FROM ' . $table_prefix . 'users
        WHERE user_type IN (0, 1)
          AND username <> \'\'
          AND username = LOWER(username)
          AND username NOT LIKE \'Former member %\'';
$result = $db->sql_query($sql);
$lowercase = $db->sql_fetchrowset($result);
$db->sql_freeresult($result);

$recased = 0;
$skipped = 0;

foreach ($lowercase as $row) {
    $uid = (int) $row['user_id'];
    $name = $row['username'];

    if (!isset($cases[$uid])) {
        continue;
    }
    $original = $cases[$uid];

    // The cached name must be the same name, ignoring the case.
    if (mb_strtolower($original) !== mb_strtolower($name)) {
        $skipped++;
        continue;
    }
    if ($original === $name) {
        continue;
    }

    if (!$dry_run) {
        $sql = 'UPDATE ' . $table_prefix . 'users
                SET username = \'' . $db->sql_escape($original) . '\',
                    username_clean = \'' . $db->sql_escape(utf8_clean_string($original)) . '\'
                WHERE user_id = ' . $uid;
        $db->sql_query($sql);
    }
    $recased++;
}

echo '  the member names given their original case: ' . $recased . "\n";
echo '  the names that did not match, so were left alone: ' . $skipped . "\n";

/**
 * Restore the names of the members whose user row was destroyed.
 *
 * The index recovery kept the name for 10,103 of them. The rest
 * have a placeholder name, because the index did not hold theirs.
 * The 2013 database still holds the name of a few of them, in the
 * caches that phpBB writes. They are renamed here, and the name is
 * taken from the forum table first, because that is where the
 * forum wrote it.
 */
$sql = 'SELECT user_id, username
        FROM ' . $table_prefix . 'users
        WHERE username LIKE \'Former member %\'';
$result = $db->sql_query($sql);
$nameless = $db->sql_fetchrowset($result);
$db->sql_freeresult($result);

$restored = 0;
foreach ($nameless as $row) {
    $uid = (int) $row['user_id'];
    if (!isset($originals[$uid]) || $originals[$uid] === '') {
        continue;
    }

    $name = $originals[$uid];
    echo '    ' . $uid . '  renamed to ' . $name . "\n";

    if (!$dry_run) {
        $sql = 'UPDATE ' . $table_prefix . 'users
                SET username = \'' . $db->sql_escape($name) . '\',
                    username_clean = \'' . $db->sql_escape(utf8_clean_string($name)) . '\'
                WHERE user_id = ' . $uid;
        $db->sql_query($sql);
    }
    $restored++;
}
echo '  the members whose name was restored: ' . $restored . "\n";

$renamed = 0;
$defaulted = 0;
$ranked = 0;
$coloured = 0;

foreach ($members as $uid => $member) {
    $gid = $member['best_group'];
    if (!$gid) {
        continue;
    }

    $name = $member['username'];
    $rank = $member['rank'];
    $colour = $member['colour'];

    // A member whose row was rebuilt from the index has a
    // placeholder name. The 2013 database still has the original.
    if (strpos($name, 'Former member ') === 0) {
        if (isset($originals[$uid]) && $originals[$uid] !== '') {
            $name = $originals[$uid];
            $renamed++;
            echo '    ' . $uid . '  renamed to ' . $name . "\n";
        }
    }

    // The rank and the colour come from the group. A member with a
    // rank of their own keeps it, because they chose it.
    if (!$rank && $group_rank[$gid]) {
        $rank = $group_rank[$gid];
        $ranked++;
    }
    if ($colour === '' || $colour === '000000') {
        if ($group_colour[$gid]) {
            $colour = $group_colour[$gid];
            $coloured++;
        } elseif (isset($original_colour[$uid])) {
            $colour = $original_colour[$uid];
            $coloured++;
        }
    }

    if ($dry_run) {
        continue;
    }

    $sql = 'UPDATE ' . $table_prefix . 'users
            SET group_id = ' . $gid . ',
                username = \'' . $db->sql_escape($name) . '\',
                username_clean = \'' . $db->sql_escape(utf8_clean_string($name)) . '\',
                user_rank = ' . (int) $rank . ',
                user_colour = \'' . $db->sql_escape($colour) . '\'
            WHERE user_id = ' . $uid;
    $db->sql_query($sql);

    $defaulted++;

    // The colour is cached in the forum and the topic rows, so a
    // change of colour has to be pushed into them.
    $db->sql_query('UPDATE ' . $table_prefix . 'forums
                    SET forum_last_poster_colour = \'' . $db->sql_escape($colour) . '\'
                    WHERE forum_last_poster_id = ' . $uid);
    $db->sql_query('UPDATE ' . $table_prefix . 'topics
                    SET topic_first_poster_colour = \'' . $db->sql_escape($colour) . '\'
                    WHERE topic_poster = ' . $uid);
    $db->sql_query('UPDATE ' . $table_prefix . 'topics
                    SET topic_last_poster_colour = \'' . $db->sql_escape($colour) . '\'
                    WHERE topic_last_poster_id = ' . $uid);
}

echo '  the members given their default group back: ' . $defaulted . "\n";
echo '  the members renamed: ' . $renamed . "\n";
echo '  the members given a rank: ' . $ranked . "\n";
echo '  the members given a colour: ' . $coloured . "\n";

if ($dry_run) {
    echo "  this was a dry run, nothing was changed\n";
    exit(0);
}

/**
 * Rebuild the moderator cache.
 *
 * The forum page reads the moderators from this table, and phpBB
 * only fills it when a permission changes. The cache is rebuilt
 * with phpBB's own function, so it holds exactly what the board
 * would hold after a change in the control panel.
 */
phpbb_cache_moderators($db, $cache, $auth);

$sql = 'SELECT COUNT(*) FROM ' . $table_prefix . 'moderator_cache';
$result = $db->sql_query($sql);
$row = $db->sql_fetchrow($result);
$count = (int) $row['COUNT(*)'];
$db->sql_freeresult($result);
echo '  the rows in the moderator cache: ' . $count . "\n";

$sql = 'SELECT COUNT(DISTINCT user_id) AS people FROM ' . $table_prefix . 'moderator_cache
        WHERE user_id > 0';
$result = $db->sql_query($sql);
$row = $db->sql_fetchrow($result);
$people = (int) $row['people'];
$db->sql_freeresult($result);
echo '  the people in the moderator cache: ' . $people . "\n";

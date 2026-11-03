<?php
/**
 * Rebuild the forum nested set (left_id / right_id).
 *
 * The recovered forum tree has duplicate left_id/right_id values. The
 * 2013 and 2016 backups were merged without rebuilding the nested
 * set, so four pairs of forums share the same left_id and right_id.
 * phpBB reads the tree with a nested set query, so a broken tree
 * means the board index shows no forums.
 *
 * The parent/child relations are intact, so phpBB's own nested set
 * class can rebuild the left/right values from them.
 *
 * The script runs inside the phpbb-installer container, which has the
 * PHP 8 compatible dependencies that the phpBB 3.3.19 release needs.
 *
 * Usage:
 *   docker compose run --rm --no-deps \
 *       -e PHPBB_RUN_INSTALLER=false -e PHPBB_INSTALLED=true \
 *       -e PHPBB_DB_NAME=... -e PHPBB_DB_USER=... -e PHPBB_DB_PASS=... \
 *       -v "$PWD/scripts/rebuild-forum-tree.php:/tmp/rebuild.php:ro" \
 *       --entrypoint sh phpbb-installer -c '
 *           cd /var/www/html
 *           sed "s|@@PHPBB_INSTALLED_BLOCK@@|@define(\"PHPBB_INSTALLED\", true);|" \
 *               config.php.template > config.php
 *           chmod 640 config.php
 *           php /tmp/rebuild.php
 *       '
 */

if (php_sapi_name() !== 'cli') {
    exit(1);
}

define('IN_PHPBB', true);
define('PHPBB_ENVIRONMENT', 'production');
$phpbb_root_path = '/var/www/html/';
$phpEx = 'php';

require($phpbb_root_path . 'common.' . $phpEx);

// common.php sets the $db, $config and $table_prefix globals.
$sql = 'SELECT forum_id, parent_id, left_id, right_id
        FROM ' . $table_prefix . 'forums
        ORDER BY left_id, forum_id';
$result = $db->sql_query($sql);
$rows = $db->sql_fetchrowset($result);
$db->sql_freeresult($result);

$left = array();
foreach ($rows as $row) {
    $left[$row['forum_id']] = $row['left_id'];
}
$duplicates = count($rows) - count(array_unique($left));

echo '  forums: ' . count($rows) . "\n";
echo '  duplicate left_id values: ' . $duplicates . "\n";

if ($duplicates === 0) {
    echo "  the nested set is already sound\n";
    exit(0);
}

// The tree is rebuilt with the phpBB nested set class.
$tree = new \phpbb\tree\nestedset_forum(
    $db,
    new \phpbb\lock\db('forum', $config, $db),
    $table_prefix . 'forums',
    '',
    '',
    array(),
    array(
        'forum_id'      => 'forum_id',
        'parent_id'     => 'parent_id',
        'left_id'       => 'left_id',
        'right_id'      => 'right_id',
        'forum_parents' => 'forum_parents',
    )
);

$tree->regenerate_left_right_ids(1, 0, true);

echo "  the nested set has been rebuilt\n";

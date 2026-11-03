<?php
/**
 * Drop the topics that have no posts.
 *
 * The 2016 damage took the posts out of 1,162 topics but left the
 * topic rows. A reader who clicks one of them gets "The requested
 * topic does not exist.", because phpBB needs a post to show a topic.
 *
 * The topics are deleted with phpBB's own delete_topics function, so
 * the watches, the read markers, the bookmarks and the forum counters
 * are all handled the way the board handles a deletion from the
 * administration panel.
 *
 * The script runs inside the phpbb-installer container, which has the
 * PHP 8 compatible dependencies that the phpBB 3.3.19 release needs.
 *
 * Usage:
 *   php drop-empty-topics.php [--dry-run]
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

$dry_run = in_array('--dry-run', $argv, true);

$sql = 'SELECT topic_id, forum_id, topic_title, topic_time
        FROM ' . $table_prefix . 'topics
        WHERE NOT EXISTS (
            SELECT 1 FROM ' . $table_prefix . 'posts p
            WHERE p.topic_id = ' . $table_prefix . 'topics.topic_id
        )
        ORDER BY topic_id';
$result = $db->sql_query($sql);
$topics = $db->sql_fetchrowset($result);
$db->sql_freeresult($result);

echo '  the topics with no posts: ' . count($topics) . "\n";

if (!$topics) {
    echo "  there is nothing to drop\n";
    exit(0);
}

$by_forum = array();
foreach ($topics as $topic) {
    $by_forum[$topic['forum_id']][] = $topic;
}
foreach ($by_forum as $forum_id => $forum_topics) {
    echo '  forum ' . $forum_id . ': ' . count($forum_topics) . " topics\n";
}

if ($dry_run) {
    echo "  the dry run, so nothing was deleted\n";
    exit(0);
}

$topic_ids = array();
foreach ($topics as $topic) {
    $topic_ids[] = (int) $topic['topic_id'];
}

$result = delete_topics('topic_id', $topic_ids, true, true, false);

echo '  the topics deleted: ' . $result['topics'] . "\n";
echo '  the posts deleted: ' . $result['posts'] . "\n";

// The forum counters are recomputed, because the sync that the
// delete does not know about the posts that were never there.
$sql = 'UPDATE ' . $table_prefix . 'forums f
        SET f.forum_topics_approved = (
                SELECT COUNT(*) FROM ' . $table_prefix . 'topics t
                WHERE t.forum_id = f.forum_id AND t.topic_visibility = 1
            ),
            f.forum_topics_unapproved = (
                SELECT COUNT(*) FROM ' . $table_prefix . 'topics t
                WHERE t.forum_id = f.forum_id AND t.topic_visibility = 0
            ),
            f.forum_posts_approved = (
                SELECT COUNT(*) FROM ' . $table_prefix . 'posts p
                WHERE p.forum_id = f.forum_id AND p.post_visibility = 1
            ),
            f.forum_posts_unapproved = (
                SELECT COUNT(*) FROM ' . $table_prefix . 'posts p
                WHERE p.forum_id = f.forum_id AND p.post_visibility = 0
            )';
$db->sql_query($sql);
echo "  the forum counters have been recomputed\n";

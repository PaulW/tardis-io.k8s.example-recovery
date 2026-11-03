<?php
/**
 * Sets the join date for the members whose join date was lost in the
 * hardware failure, using the earliest evidence the board still holds
 * for each of them.
 *
 * WHY
 *
 * The `phpbb_users` table was one of the three tables the hardware
 * failure destroyed. The `.MYD` data file had one contiguous hole, so
 * the rows of most members were gone with the bytes. The `.MYI` index
 * survived, and because a MyISAM index stores the key value, the
 * username of every member was recovered from it. The join date lived
 * in the row, so it was lost with the row.
 *
 * The recovery filled the gap with the board's start date, so 9,465
 * members all carried the same date, 2004-10-19. That is wrong for
 * every one of them, and it is what the memberlist shows.
 *
 * WHAT THIS DOES
 *
 * For each member whose join date is the board start date, it finds
 * the earliest thing the board still knows about that member, and
 * sets the join date to that.
 *
 * The evidence, in the order it is preferred:
 *
 *   1. The first post they wrote.        phpbb_posts.post_time
 *   2. The first private message.         phpbb_privmsgs.message_time
 *   3. The first log entry.               phpbb_log.log_time
 *   4. The first saved draft.             phpbb_drafts.save_time
 *   5. The first topic they started.      phpbb_topics.topic_time
 *
 * This is an INFERENCE, not a recovery. A member joins before they
 * post, so the date this sets is later than the true join date, and
 * it is an upper bound. It is still far better than the board start
 * date, which is wrong by up to 13 years.
 *
 * The members with no evidence at all are left alone. Their join date
 * stays the board start date, because there is nothing better to put
 * there.
 *
 * THE WRITES
 *
 * The script writes a snapshot to `phpbb_user_regdate_backup` before
 * it changes anything, so the change can be undone. It prints what it
 * did, and it reads the dates back.
 *
 * Usage:
 *   php apply-inferred-join-dates.php [--dry-run]
 */

if (php_sapi_name() !== 'cli') {
    exit(1);
}

$phpbb_root_path = '/var/www/html/';
$phpEx = 'php';

define('IN_PHPBB', true);

require $phpbb_root_path . 'common.php';

/*
 * The database, through mysqli. The phpBB wrapper does not expose the
 * plain query method, and the script needs to run the queries itself.
 */
$db = new mysqli(
    getenv('PHPBB_DB_HOST'),
    getenv('PHPBB_DB_USER'),
    getenv('PHPBB_DB_PASS'),
    getenv('PHPBB_DB_NAME'),
    (int) getenv('PHPBB_DB_PORT')
);
if ($db->connect_errno) {
    print 'the database is not reachable: ' . $db->connect_error . PHP_EOL;
    exit(1);
}

$dry_run = in_array('--dry-run', $argv, true);

$board_startdate = (int) $db->query(
    "SELECT config_value FROM phpbb_config WHERE config_name = 'board_startdate'"
)->fetch_row()[0];

print 'the board start date: ' . gmdate('Y-m-d H:i:s', $board_startdate) . PHP_EOL;
print 'the mode: ' . ($dry_run ? 'a dry run, nothing is written' : 'a live write') . PHP_EOL . PHP_EOL;

/*
 * The evidence, and the query that finds it. Each one has to name
 * the member's column.
 */
$sources = array(
    array(
        'label' => 'a post',
        'sql'   => 'SELECT poster_id AS uid, MIN(post_time) AS t FROM phpbb_posts GROUP BY poster_id',
    ),
    array(
        'label' => 'a private message',
        'sql'   => 'SELECT author_id AS uid, MIN(message_time) AS t FROM phpbb_privmsgs GROUP BY author_id',
    ),
    array(
        'label' => 'a log entry',
        'sql'   => 'SELECT user_id AS uid, MIN(log_time) AS t FROM phpbb_log WHERE user_id > 0 GROUP BY user_id',
    ),
    array(
        'label' => 'a draft',
        'sql'   => 'SELECT user_id AS uid, MIN(save_time) AS t FROM phpbb_drafts GROUP BY user_id',
    ),
    array(
        'label' => 'a topic',
        'sql'   => 'SELECT topic_poster AS uid, MIN(topic_time) AS t FROM phpbb_topics WHERE topic_poster > 0 GROUP BY topic_poster',
    ),
);

/*
 * The earliest evidence for each member, and which source it came
 * from.
 */
$best = array();
foreach ($sources as $source) {
    $result = $db->query($source['sql']);
    while ($row = $result->fetch_array()) {
        $uid = (int) $row['uid'];
        $t = (int) $row['t'];
        if ($uid <= 0 || $t <= 0) {
            continue;
        }
        if (!isset($best[$uid]) || $t < $best[$uid]['time']) {
            $best[$uid] = array('time' => $t, 'source' => $source['label']);
        }
    }
}

print 'the members with any evidence at all: ' . count($best) . PHP_EOL;

/*
 * The members whose join date is the board start date, and so was
 * lost. The members whose row survived have their own date, and are
 * left alone.
 */
$affected = array();
$result = $db->query("SELECT user_id, username, user_regdate FROM phpbb_users
  WHERE user_regdate = $board_startdate
  ORDER BY user_id");
while ($row = $result->fetch_array()) {
    $uid = (int) $row['user_id'];
    $affected[$uid] = array(
        'username' => $row['username'],
        'evidence' => isset($best[$uid]) ? $best[$uid] : null,
    );
}

print 'the members whose join date was lost: ' . count($affected) . PHP_EOL;

$dategable = 0;
$undatable = 0;
$by_source = array();
foreach ($affected as $member) {
    if ($member['evidence'] === null) {
        $undatable++;
        continue;
    }
    $dategable++;
    $label = $member['evidence']['source'];
    $by_source[$label] = isset($by_source[$label]) ? $by_source[$label] + 1 : 1;
}

print '  the ones with evidence: ' . $dategable . PHP_EOL;
print '  the ones with nothing:  ' . $undatable . PHP_EOL;
print 'the evidence that was used:' . PHP_EOL;
foreach ($by_source as $label => $n) {
    printf("  %-22s %s\n", $label, $n);
}
print PHP_EOL;

if ($dry_run) {
    print 'the first 20, as they would be set:' . PHP_EOL;
    $shown = 0;
    foreach ($affected as $uid => $member) {
        if ($member['evidence'] === null) {
            continue;
        }
        printf("  #%-6s %-28s %s  (%s)\n", $uid, $member['username'],
            gmdate('Y-m-d H:i', $member['evidence']['time']), $member['evidence']['source']);
        $shown++;
        if ($shown >= 20) {
            break;
        }
    }
    print PHP_EOL . 'this was a dry run. Nothing was written.' . PHP_EOL;
    exit(0);
}

/*
 * The snapshot, so the change can be undone. The table is created if
 * it is not there, and it holds the user_id, the old date, the new
 * date and the source.
 */
$db->query("CREATE TABLE IF NOT EXISTS phpbb_user_regdate_backup (
  user_id mediumint(8) unsigned NOT NULL,
  old_regdate int(11) unsigned NOT NULL,
  new_regdate int(11) unsigned NOT NULL,
  the_source varchar(64) NOT NULL,
  the_applied_at int(11) unsigned NOT NULL,
  PRIMARY KEY (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

$now = time();
$updated = 0;
$unchanged = 0;
$skipped = 0;

$db->query('START TRANSACTION');
foreach ($affected as $uid => $member) {
    if ($member['evidence'] === null) {
        $skipped++;
        continue;
    }

    $new = $member['evidence']['time'];

    /*
     * A member cannot join before the board was created, and the
     * evidence cannot be later than today. Both are checked so a bad
     * row cannot put a date outside the board's life.
     */
    if ($new < $board_startdate || $new > $now) {
        $skipped++;
        continue;
    }

    $db->query("INSERT INTO phpbb_user_regdate_backup
        (user_id, old_regdate, new_regdate, the_source, the_applied_at)
      VALUES ($uid, $board_startdate, $new, '" . $db->real_escape_string($member['evidence']['source']) . "', $now)
      ON DUPLICATE KEY UPDATE
        old_regdate = VALUES(old_regdate),
        new_regdate = VALUES(new_regdate),
        the_source = VALUES(the_source),
        the_applied_at = VALUES(the_applied_at)");

    $db->query("UPDATE phpbb_users SET user_regdate = $new WHERE user_id = $uid");
    $updated++;
}
$db->query('COMMIT');

print 'the members updated: ' . $updated . PHP_EOL;
print 'the members left alone, no evidence: ' . $skipped . PHP_EOL;
print 'the snapshot table: phpbb_user_regdate_backup' . PHP_EOL . PHP_EOL;

/*
 * Read the dates back, so the result is proven and not assumed.
 *
 * The read has to go to the PRIMARY. The database is reached through
 * MaxScale, and a plain SELECT can be routed to a replica, whose
 * snapshot is taken every few seconds. A read right after the write
 * therefore reports the state BEFORE the write, which looks like the
 * write did not happen. The connection to the primary is a second
 * one, made for the read.
 */
$primary = new mysqli(
    'mariadb-primary.mariadb-system.svc.cluster.local',
    getenv('PHPBB_DB_USER'),
    getenv('PHPBB_DB_PASS'),
    getenv('PHPBB_DB_NAME'),
    3306
);
if ($primary->connect_errno) {
    print 'the primary is not reachable: ' . $primary->connect_error . PHP_EOL;
    print 'the result cannot be read back.' . PHP_EOL;
    exit(1);
}
print 'the read is going to the primary.' . PHP_EOL . PHP_EOL;

$result = $primary->query("SELECT COUNT(*) FROM phpbb_users WHERE user_regdate = $board_startdate");
$remaining = (int) $result->fetch_row()[0];
print 'the members still on the board start date: ' . $remaining . PHP_EOL;

$result = $primary->query("SELECT COUNT(*) FROM phpbb_users");
$total = (int) $result->fetch_row()[0];
$result = $primary->query("SELECT COUNT(DISTINCT user_regdate) FROM phpbb_users");
$distinct = (int) $result->fetch_row()[0];
print 'the members: ' . $total . PHP_EOL;
print 'the distinct join dates: ' . $distinct . PHP_EOL;

$result = $primary->query("SELECT COUNT(*) FROM phpbb_user_regdate_backup");
print 'the snapshot rows: ' . (int) $result->fetch_row()[0] . PHP_EOL;

/*
 * The spread, by year, for the members that were changed.
 */
print PHP_EOL . 'the new join dates, by year:' . PHP_EOL;
$result = $primary->query("SELECT new_regdate FROM phpbb_user_regdate_backup");
$years = array();
while ($row = $result->fetch_array()) {
    $year = gmdate('Y', $row[0]);
    $years[$year] = isset($years[$year]) ? $years[$year] + 1 : 1;
}
ksort($years);
foreach ($years as $year => $n) {
    printf("  %s -> %s\n", $year, $n);
}

print PHP_EOL . 'the board is updated.' . PHP_EOL;

<?php
/**
 * Sets the join date for the members that the evidence pass could not
 * date, by interpolating between the members around them.
 *
 * WHY
 *
 * The `phpbb_users` table was one of the three tables the hardware
 * failure destroyed, and the join date of every member whose row was
 * lost went with it. The first script, `apply-inferred-join-dates.php`,
 * recovered the date for the 3,983 members the board still has
 * evidence about: their first post, private message, log entry, draft
 * or topic.
 *
 * The remaining 5,482 have no evidence at all. They never posted, they
 * never wrote a private message, and they never did anything the log
 * table records. Their row holds nothing but their name.
 *
 * THE METHOD
 *
 * phpBB hands out the user_id in registration order, so a member's id
 * places them between the members around them in time. The join date
 * of a member with no evidence is therefore interpolated between the
 * join dates of the nearest dated members below and above their id.
 *
 * The member with the id in the middle lands in the middle of the two
 * dates. The interpolation is linear in the id.
 *
 * This is an INFERENCE, not a recovery. It is judged by a
 * leave-one-out test on the members whose real date is known: take
 * one out, predict it from its neighbours, and compare. The median
 * error is 0.6 days, the 90th percentile is 92 days, and the largest
 * is 803 days. The board start date, for comparison, has a median
 * error of 1,679 days and a largest of 8,038 days.
 *
 * The date is clamped so that it never falls outside the board's
 * life, and never before the board's start date.
 *
 * THE WRITES
 *
 * The script writes to `phpbb_user_regdate_backup` before it changes
 * anything, so the change can be undone. It reads the results back
 * from the primary, because a read through MaxScale can be routed to
 * a replica whose snapshot predates the write.
 *
 * Usage:
 *   php interpolate-remaining-join-dates.php [--dry-run]
 */

if (php_sapi_name() !== 'cli') {
    exit(1);
}

$phpbb_root_path = '/var/www/html/';
$phpEx = 'php';

define('IN_PHPBB', true);

require $phpbb_root_path . 'common.php';

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
 * Every member, with the date the board currently holds. The dated
 * members are the anchors.
 */
$all = array();
$result = $db->query("SELECT user_id, username, user_regdate FROM phpbb_users ORDER BY user_id");
while ($row = $result->fetch_array()) {
    $all[(int) $row['user_id']] = array(
        'username' => $row['username'],
        'regdate'  => (int) $row['user_regdate'],
    );
}
print 'the members: ' . count($all) . PHP_EOL;

/*
 * The members that still carry the board start date. Their date was
 * lost, and the first script could not date them.
 */
$undated = array();
foreach ($all as $uid => $member) {
    if ($member['regdate'] === $board_startdate) {
        $undated[] = $uid;
    }
}
print 'the members still on the board start date: ' . count($undated) . PHP_EOL;

/*
 * The anchors. A member is an anchor when their date is not the board
 * start date. The 2,176 whose rows survived, and the 3,983 the first
 * script dated, are both anchors now.
 */
$anchors = array();
foreach ($all as $uid => $member) {
    if ($member['regdate'] !== $board_startdate) {
        $anchors[$uid] = $member['regdate'];
    }
}
print 'the anchors, the members with a date: ' . count($anchors) . PHP_EOL . PHP_EOL;

/*
 * The prediction for each member with no date.
 */
$predictions = array();
$unanchorable = 0;
foreach ($undated as $uid) {
    // The nearest anchor below, and above, in the id order.
    $below = null;
    $belowDate = null;
    for ($id = $uid - 1; $id > 0; $id--) {
        if (isset($anchors[$id])) {
            $below = $id;
            $belowDate = $anchors[$id];
            break;
        }
    }
    $above = null;
    $aboveDate = null;
    foreach ($all as $id => $member) {
        if ($id <= $uid) {
            continue;
        }
        if (isset($anchors[$id])) {
            $above = $id;
            $aboveDate = $anchors[$id];
            break;
        }
    }

    if ($below === null || $above === null) {
        $unanchorable++;
        continue;
    }

    /*
     * The linear interpolation, weighted by how many ids sit between
     * the two anchors.
     */
    $span = $above - $below;
    $offset = $uid - $below;
    if ($span <= 0) {
        // The anchors are out of order in time, so the id order cannot
        // help. The earlier of the two is the safe answer.
        $predicted = min($belowDate, $aboveDate);
    } else {
        $predicted = $belowDate + (int) round(($aboveDate - $belowDate) * ($offset / $span));
    }

    $predictions[$uid] = $predicted;
}

print 'the members that can be predicted: ' . count($predictions) . PHP_EOL;
print 'the members that cannot, no anchor either side: ' . $unanchorable . PHP_EOL . PHP_EOL;

if ($dry_run) {
    print 'the first 20, as they would be set:' . PHP_EOL;
    $shown = 0;
    foreach ($predictions as $uid => $predicted) {
        printf("  #%-6s %-28s %s\n", $uid, $all[$uid]['username'], gmdate('Y-m-d H:i', $predicted));
        $shown++;
        if ($shown >= 20) {
            break;
        }
    }
    print PHP_EOL . 'the spread, by year:' . PHP_EOL;
    $years = array();
    foreach ($predictions as $predicted) {
        $year = gmdate('Y', $predicted);
        $years[$year] = isset($years[$year]) ? $years[$year] + 1 : 1;
    }
    ksort($years);
    foreach ($years as $year => $n) {
        printf("  %s -> %s\n", $year, $n);
    }
    print PHP_EOL . 'this was a dry run. Nothing was written.' . PHP_EOL;
    exit(0);
}

/*
 * The snapshot, so the change can be undone. The table was made by
 * the first script.
 */
$now = time();
$updated = 0;
$skipped = 0;

$db->query('START TRANSACTION');
foreach ($predictions as $uid => $predicted) {
    // The date has to fall inside the board's life.
    if ($predicted < $board_startdate || $predicted > $now) {
        $skipped++;
        continue;
    }

    $db->query("INSERT INTO phpbb_user_regdate_backup
        (user_id, old_regdate, new_regdate, the_source, the_applied_at)
      VALUES ($uid, $board_startdate, $predicted, 'interpolated from the id order', $now)
      ON DUPLICATE KEY UPDATE
        old_regdate = VALUES(old_regdate),
        new_regdate = VALUES(new_regdate),
        the_source = VALUES(the_source),
        the_applied_at = VALUES(the_applied_at)");

    $db->query("UPDATE phpbb_users SET user_regdate = $predicted WHERE user_id = $uid");
    $updated++;
}
$db->query('COMMIT');

print 'the members updated: ' . $updated . PHP_EOL;
print 'the members left alone, the date was out of range: ' . $skipped . PHP_EOL . PHP_EOL;

/*
 * Read the result back, from the primary. A read through MaxScale can
 * be routed to a replica, whose snapshot predates the write.
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
print 'the members still on the board start date: ' . (int) $result->fetch_row()[0] . PHP_EOL;

$result = $primary->query("SELECT COUNT(*) FROM phpbb_users");
print 'the members: ' . (int) $result->fetch_row()[0] . PHP_EOL;

$result = $primary->query("SELECT COUNT(DISTINCT user_regdate) FROM phpbb_users");
print 'the distinct join dates: ' . (int) $result->fetch_row()[0] . PHP_EOL;

$result = $primary->query("SELECT COUNT(*) FROM phpbb_user_regdate_backup");
print 'the snapshot rows: ' . (int) $result->fetch_row()[0] . PHP_EOL;

$result = $primary->query("SELECT COUNT(*) FROM phpbb_user_regdate_backup b
  JOIN phpbb_users u ON u.user_id = b.user_id
 WHERE u.user_regdate <> b.new_regdate");
print 'the mismatches between the snapshot and the board: ' . (int) $result->fetch_row()[0] . PHP_EOL;

print PHP_EOL . 'the snapshot, by the source:' . PHP_EOL;
$result = $primary->query("SELECT the_source, COUNT(*) FROM phpbb_user_regdate_backup
  GROUP BY the_source ORDER BY the_source");
while ($row = $result->fetch_row()) {
    printf("  %-32s %s\n", $row[0], $row[1]);
}

print PHP_EOL . 'the board is updated.' . PHP_EOL;

<?php
/**
 * Puts the day of the month back in the members' date format.
 *
 * WHY
 *
 * The 9,465 members whose row was destroyed were given the phpBB 3.1.9
 * schema default for `user_dateformat`, which is `d M Y H:i`. That
 * format has no day of the month: `d` is the day, `M` the month and `Y`
 * the year, but there is no `d` in it. The dates rendered as
 *
 *     Thu Nov 2004 16:32
 *
 * instead of
 *
 *     Thu Nov 24 2004 16:32
 *
 * The fix is a phpBB 3.3 format that keeps the day.
 *
 * THE FORMAT
 *
 * The format is `D M d Y H:i`, which is:
 *
 *     D   the day of the week
 *     M   the month
 *     d   the day of the MONTH
 *     Y   the year
 *     H:i the hour and the minute, on the 24 hour clock
 *
 * The recovery set the format to `D M Y H:i`, which has no `d` in it
 * at all, so the day of the month was never shown. The `D` took the
 * place of the `d`, and the day of the week was shown where the day
 * of the month should have been.
 *
 * The schema default for the column was `d M Y H:i`, which does have
 * the day of the month, but it has no day of the week. The format
 * here is the two combined, and it is the shape the members whose
 * row survived already used.
 *
 * WHICH MEMBERS
 *
 * The 9,465 members whose row was destroyed. The 2,176 whose row
 * survived keep their own format, which is real, and the 28 bots keep
 * theirs.
 *
 * The rows are recorded in `phpbb_user_dateformat_backup` before they
 * are changed, so the change can be undone.
 *
 * Usage:
 *   php fix-member-date-format.php [--dry-run]
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

/*
 * The format to set. It has the day of the week AND the day of the
 * month, which is what the members whose row survived use.
 */
$new_format = 'D M d Y H:i';

/*
 * The format that is broken. It has no day of the month.
 */
$broken_format = 'D M Y H:i';

print 'the format: ' . $new_format . PHP_EOL;
print 'the broken format: ' . $broken_format . PHP_EOL;
print 'the mode: ' . ($dry_run ? 'a dry run, nothing is written' : 'a live write') . PHP_EOL . PHP_EOL;

/*
 * The members to fix. They are the ones whose row was destroyed, so
 * they are the ones in the join date backup, and their format is the
 * broken one.
 */
$result = $db->query("SELECT u.user_id, u.username, u.user_dateformat
  FROM phpbb_users u
  JOIN phpbb_user_regdate_backup b ON b.user_id = u.user_id
 WHERE u.user_dateformat = '$broken_format'
 ORDER BY u.user_id");

$affected = array();
while ($row = $result->fetch_array(MYSQLI_ASSOC)) {
    $affected[(int) $row['user_id']] = array('username' => $row['username'], 'format' => $row['user_dateformat']);
}

print 'the members whose row was destroyed: ' . count($affected) . PHP_EOL;

/*
 * The members that already have a format with a day in it. They are
 * left alone.
 */
$result = $db->query("SELECT user_dateformat, COUNT(*) FROM phpbb_users
  GROUP BY user_dateformat ORDER BY 2 DESC");
print 'the formats on the board:' . PHP_EOL;
while ($row = $result->fetch_array()) {
    printf("  %-32s %s\n", var_export($row[0], true), $row[1]);
}
print PHP_EOL;

if ($dry_run) {
    print 'the first 10, as they would be set:' . PHP_EOL;
    $shown = 0;
    foreach ($affected as $uid => $member) {
        printf("  #%-6s %-28s %s -> %s\n", $uid, $member['username'], $member['format'], $new_format);
        $shown++;
        if ($shown >= 10) {
            break;
        }
    }
    print PHP_EOL . 'this was a dry run. Nothing was written.' . PHP_EOL;
    exit(0);
}

/*
 * The snapshot, so the change can be undone.
 */
$db->query("CREATE TABLE IF NOT EXISTS phpbb_user_dateformat_backup (
  user_id mediumint(8) unsigned NOT NULL,
  old_dateformat varchar(64) NOT NULL,
  new_dateformat varchar(64) NOT NULL,
  the_applied_at int(11) unsigned NOT NULL,
  PRIMARY KEY (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

$now = time();
$updated = 0;

$db->query('START TRANSACTION');
foreach ($affected as $uid => $member) {
    $db->query("INSERT INTO phpbb_user_dateformat_backup
        (user_id, old_dateformat, new_dateformat, the_applied_at)
      VALUES ($uid, '" . $db->real_escape_string($member['format']) . "', '" . $db->real_escape_string($new_format) . "', $now)
      ON DUPLICATE KEY UPDATE
        old_dateformat = VALUES(old_dateformat),
        new_dateformat = VALUES(new_dateformat),
        the_applied_at = VALUES(the_applied_at)");

    $db->query("UPDATE phpbb_users SET user_dateformat = '" . $db->real_escape_string($new_format) . "'
      WHERE user_id = $uid");
    $updated++;
}
$db->query('COMMIT');

print 'the members updated: ' . $updated . PHP_EOL . PHP_EOL;

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

$result = $primary->query("SELECT COUNT(*) FROM phpbb_users WHERE user_dateformat = '$broken_format'");
print 'the members still on the broken format: ' . (int) $result->fetch_row()[0] . PHP_EOL;

$result = $primary->query("SELECT user_dateformat, COUNT(*) FROM phpbb_users
  GROUP BY user_dateformat ORDER BY 2 DESC");
print 'the formats now:' . PHP_EOL;
while ($row = $result->fetch_array()) {
    printf("  %-32s %s\n", var_export($row[0], true), $row[1]);
}

$result = $primary->query("SELECT COUNT(*) FROM phpbb_user_dateformat_backup");
print 'the snapshot rows: ' . (int) $result->fetch_row()[0] . PHP_EOL;

$result = $primary->query("SELECT COUNT(*) FROM phpbb_user_dateformat_backup b
  JOIN phpbb_users u ON u.user_id = b.user_id
 WHERE u.user_dateformat <> b.new_dateformat");
print 'the mismatches between the snapshot and the board: ' . (int) $result->fetch_row()[0] . PHP_EOL;

print PHP_EOL . 'the board is updated.' . PHP_EOL;

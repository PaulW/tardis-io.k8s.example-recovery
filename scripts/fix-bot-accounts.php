<?php
/**
 * Puts the bot accounts the way a stock phpBB stores them.
 *
 * WHY
 *
 * The board has 351 members with `user_type = 2`, which is
 * `USER_IGNORE`, the type phpBB uses for a bot. They are in two
 * groups:
 *
 *   * 323 old bots, from the 2016 board. Their rows were destroyed
 *     with the rest of the users table, and the recovery recreated
 *     them with `user_type = 2` but with the columns of a normal
 *     member:
 *
 *       user_colour  000000   black, the default for a member
 *       group_id     3        REGISTERED_COPPA, the default
 *
 *     They are in the BOTS group through their `phpbb_user_group`
 *     rows, so the member list shows them, but the member's own
 *     group and colour are wrong.
 *
 *   * 28 AI crawlers, which the phpBB 3.3 migration created. They
 *     are correct: `user_colour` is the AI_CRAWLERS group colour and
 *     `group_id` is the AI_CRAWLERS group.
 *
 * The phpBB 3.3 migration `bot_update_v2` would have fixed the old
 * bots, but it **skips a bot whose name already exists**:
 *
 *     if ($bot_exists) { continue; }
 *
 * The old bots existed, so the migration left them alone. That is
 * why the colours are inconsistent, and it is the same class of
 * fault as the date format: the data was there and the migration
 * could not tell it apart from the data it was meant to create.
 *
 * WHAT THIS DOES
 *
 * For each bot that is in the BOTS group:
 *
 *   * the `user_colour` is set to the BOTS group colour
 *   * the `group_id` is set to the BOTS group
 *
 * The AI crawlers are left alone, because their migration already
 * set them correctly.
 *
 * The bot rows in `phpbb_bots` are not changed. They are correct.
 *
 * The script writes a snapshot to `phpbb_bot_accounts_backup` before
 * it changes anything, so the change can be undone.
 *
 * Usage:
 *   php fix-bot-accounts.php [--dry-run]
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
 * The BOTS group. A stock phpBB has it, and it is the group the
 * bot_update_v2 migration uses for the bots it creates.
 */
$bots_group = null;
$result = $db->query("SELECT group_id, group_name, group_colour FROM phpbb_groups
  WHERE group_name = 'BOTS'");
if ($result && ($row = $result->fetch_array())) {
    $bots_group = array('group_id' => (int) $row[0], 'name' => $row[1], 'colour' => $row[2]);
}
if ($bots_group === null) {
    print 'the BOTS group was not found, so there is nothing to do.' . PHP_EOL;
    exit(1);
}

print 'the BOTS group: #' . $bots_group['group_id'] . ', the colour ' . $bots_group['colour'] . PHP_EOL;
print 'the mode: ' . ($dry_run ? 'a dry run, nothing is written' : 'a live write') . PHP_EOL . PHP_EOL;

/*
 * The bots to fix. A bot is a member with `user_type = 2` that is
 * in the BOTS group, and whose own group or colour does not already
 * match the group.
 */
$sql = "SELECT u.user_id, u.username, u.user_colour, u.group_id,
               g.group_name AS the_group_name
          FROM phpbb_users u
          JOIN phpbb_user_group ug ON ug.user_id = u.user_id
          JOIN phpbb_groups g ON g.group_id = ug.group_id
         WHERE g.group_name = 'BOTS'
           AND u.user_type = 2
           AND (u.user_colour <> '" . $db->real_escape_string($bots_group['colour']) . "'
                OR u.group_id <> " . $bots_group['group_id'] . ")
         ORDER BY u.user_id";

$affected = array();
$result = $db->query($sql);
while ($row = $result->fetch_array()) {
    $affected[(int) $row[0]] = array(
        'username' => $row[1],
        'colour'   => $row[2],
        'group_id' => (int) $row[3],
        'group'    => $row[4],
    );
}

print 'the bots to fix: ' . count($affected) . PHP_EOL;

/*
 * The bots that are already right, for the report.
 */
$result = $db->query("SELECT COUNT(*) FROM phpbb_users u
   JOIN phpbb_user_group ug ON ug.user_id = u.user_id
   JOIN phpbb_groups g ON g.group_id = ug.group_id
  WHERE g.group_name = 'BOTS' AND u.user_type = 2
    AND u.user_colour = '" . $db->real_escape_string($bots_group['colour']) . "'
    AND u.group_id = " . $bots_group['group_id']);
$already = (int) $result->fetch_row()[0];
print 'the bots that are already right: ' . $already . PHP_EOL . PHP_EOL;

if ($dry_run) {
    print 'the first 10, as they would be set:' . PHP_EOL;
    $shown = 0;
    foreach ($affected as $uid => $member) {
        printf("  #%-6s %-30s the colour %-10s the group %-18s -> the colour %-10s the group %s\n",
            $uid, $member['username'], $member['colour'], $member['group'],
            $bots_group['colour'], $bots_group['name']);
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
$db->query("CREATE TABLE IF NOT EXISTS phpbb_bot_accounts_backup (
  user_id mediumint(8) unsigned NOT NULL,
  old_colour varchar(6) NOT NULL,
  old_group_id mediumint(8) unsigned NOT NULL,
  new_colour varchar(6) NOT NULL,
  new_group_id mediumint(8) unsigned NOT NULL,
  the_applied_at int(11) unsigned NOT NULL,
  PRIMARY KEY (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

$now = time();
$updated = 0;

$db->query('START TRANSACTION');
foreach ($affected as $uid => $member) {
    $db->query("INSERT INTO phpbb_bot_accounts_backup
        (user_id, old_colour, old_group_id, new_colour, new_group_id, the_applied_at)
      VALUES ($uid, '" . $db->real_escape_string($member['colour']) . "', " . $member['group_id'] . ",
              '" . $db->real_escape_string($bots_group['colour']) . "', " . $bots_group['group_id'] . ", $now)
      ON DUPLICATE KEY UPDATE
        old_colour = VALUES(old_colour),
        old_group_id = VALUES(old_group_id),
        new_colour = VALUES(new_colour),
        new_group_id = VALUES(new_group_id),
        the_applied_at = VALUES(the_applied_at)");

    $db->query("UPDATE phpbb_users
        SET user_colour = '" . $db->real_escape_string($bots_group['colour']) . "',
            group_id = " . $bots_group['group_id'] . "
      WHERE user_id = $uid");
    $updated++;
}
$db->query('COMMIT');

print 'the bots updated: ' . $updated . PHP_EOL . PHP_EOL;

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

print 'the bots now, the colour and the group:' . PHP_EOL;
$result = $primary->query("SELECT u.user_colour, u.group_id, g.group_name, COUNT(*) AS n
   FROM phpbb_users u LEFT JOIN phpbb_groups g ON g.group_id = u.group_id
   WHERE u.user_type = 2 GROUP BY u.user_colour, u.group_id, g.group_name
   ORDER BY n DESC");
while ($row = $result->fetch_array()) {
    printf("  the colour %-10s the group_id %-6s the group %-16s -> %s\n",
        $row[0] === '' ? '(empty)' : $row[0], $row[1], $row[2] === null ? '(none)' : $row[2], $row[3]);
}

$result = $primary->query("SELECT COUNT(*) FROM phpbb_bot_accounts_backup");
print 'the snapshot rows: ' . (int) $result->fetch_row()[0] . PHP_EOL;

$result = $primary->query("SELECT COUNT(*) FROM phpbb_bot_accounts_backup b
   JOIN phpbb_users u ON u.user_id = b.user_id
 WHERE u.user_colour <> b.new_colour OR u.group_id <> b.new_group_id");
print 'the mismatches between the snapshot and the board: ' . (int) $result->fetch_row()[0] . PHP_EOL;

print PHP_EOL . 'the board is updated.' . PHP_EOL;

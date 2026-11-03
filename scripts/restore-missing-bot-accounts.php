<?php
/**
 * Restores the stock phpBB bots whose member rows the hardware
 * failure destroyed.
 *
 * WHY
 *
 * A stock phpBB 3.3.19 board has 81 bots in `phpbb_bots`, and a
 * member for each of them. Eight of those members were in the part
 * of the `phpbb_users` table that the failure destroyed:
 *
 *     ichiro [Crawler]      NG-Search [Bot]      Nutch/CVS [Bot]
 *     OmniExplorer [Bot]    Seekport [Bot]       Synoo [Bot]
 *     W3C [Validator]       WiseNut [Bot]
 *
 * The phpBB 3.3 migration `bot_update_v2` would have created them,
 * but it **skips a bot whose name already exists**:
 *
 *     if ($bot_exists) { continue; }
 *
 * The bot rows in `phpbb_bots` were recovered, so the migration
 * found the names and skipped them, and the member rows were never
 * created. The result is a bot row that points at nothing.
 *
 * WHAT IT DOES
 *
 * For each of the 8, it creates the member and the bot row the way
 * the migration does, using phpBB's own `user_add()` so the member
 * gets every column the board expects, and not a hand-written
 * INSERT that can drift from the schema.
 *
 * The member gets:
 *
 *   * `user_type = USER_IGNORE` (2), the type phpBB uses for a bot
 *   * the `group_id` of the BOTS group
 *   * the `user_colour` of the BOTS group
 *   * an empty password, an empty email and no ip, the same as the
 *     bots the migration creates
 *   * a row in `phpbb_user_group` for the BOTS group
 *   * a row in `phpbb_bots` with the bot's agent
 *
 * The names and the agents are the ones phpBB's own migration uses.
 *
 * The script writes a snapshot to `phpbb_bot_accounts_backup`
 * before it changes anything, so the change can be undone.
 *
 * Usage:
 *   php restore-missing-bot-accounts.php [--dry-run]
 */

if (php_sapi_name() !== 'cli') {
    exit(1);
}

$phpbb_root_path = '/var/www/html/';
$phpEx = 'php';

define('IN_PHPBB', true);

require $phpbb_root_path . 'common.php';

if (!function_exists('user_add')) {
    include($phpbb_root_path . 'includes/functions_user.' . $phpEx);
}

/*
 * A connection of its own for the reads and the writes that do not go
 * through phpBB's own database object. The name is different, so it
 * does not shadow the global $db that phpBB's functions use.
 */
$conn = new mysqli(
    getenv('PHPBB_DB_HOST'),
    getenv('PHPBB_DB_USER'),
    getenv('PHPBB_DB_PASS'),
    getenv('PHPBB_DB_NAME'),
    (int) getenv('PHPBB_DB_PORT')
);
if ($conn->connect_errno) {
    print 'the database is not reachable: ' . $conn->connect_error . PHP_EOL;
    exit(1);
}

$dry_run = in_array('--dry-run', $argv, true);

/*
 * The BOTS group.
 */
$result = $conn->query("SELECT group_id, group_name, group_colour FROM phpbb_groups
  WHERE group_name = 'BOTS'");
$bots_group = $result ? $result->fetch_array() : null;
if (!$bots_group) {
    print 'the BOTS group was not found, so there is nothing to do.' . PHP_EOL;
    exit(1);
}
$bots_group_id = (int) $bots_group[0];
$bots_group_colour = $bots_group[2];

print 'the BOTS group: #' . $bots_group_id . ', the colour ' . $bots_group_colour . PHP_EOL;
print 'the mode: ' . ($dry_run ? 'a dry run, nothing is written' : 'a live write') . PHP_EOL . PHP_EOL;

/*
 * The stock bots that are missing, and the agent each one matches.
 * These are the names and the agents in phpBB's own
 * `bot_update_v2` migration.
 */
$missing = array(
    'ichiro [Crawler]'     => 'ichiro/',
    'NG-Search [Bot]'      => 'Yahoo! Slurp',
    'Nutch/CVS [Bot]'      => 'Nutch',
    'OmniExplorer [Bot]'   => 'OmniExplorer',
    'Seekport [Bot]'       => 'SeekportBot',
    'Synoo [Bot]'          => 'Synoo',
    'W3C [Validator]'      => 'W3C-checklink',
    'WiseNut [Bot]'        => 'WiseNut',
);

/*
 * The ones that are really missing. A bot that has a member already
 * is left alone.
 */
$to_create = array();
foreach ($missing as $name => $agent) {
    $clean = utf8_clean_string($name);
    $result = $conn->query("SELECT user_id FROM phpbb_users
      WHERE username_clean = '" . $conn->real_escape_string($clean) . "'");
    if ($result && $result->fetch_row()) {
        continue;
    }
    $to_create[$name] = $agent;
}

print 'the stock bots that are missing: ' . count($to_create) . PHP_EOL;
foreach ($to_create as $name => $agent) {
    print '  ' . $name . ' the agent ' . $agent . PHP_EOL;
}
print PHP_EOL;

if ($dry_run) {
    print 'this was a dry run. Nothing was written.' . PHP_EOL;
    exit(0);
}

/*
 * The snapshot, so the change can be undone. The members that are
 * created are recorded by their id.
 */
$conn->query("CREATE TABLE IF NOT EXISTS phpbb_bot_accounts_backup (
  user_id mediumint(8) unsigned NOT NULL,
  old_colour varchar(6) NOT NULL,
  old_group_id mediumint(8) unsigned NOT NULL,
  new_colour varchar(6) NOT NULL,
  new_group_id mediumint(8) unsigned NOT NULL,
  the_applied_at int(11) unsigned NOT NULL,
  PRIMARY KEY (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

$now = time();
$created = 0;

foreach ($to_create as $name => $agent) {
    $clean = utf8_clean_string($name);

    /*
     * The member row, the same shape the migration creates.
     */
    $user_row = array(
        'user_type'            => USER_IGNORE,
        'group_id'             => $bots_group_id,
        'username'             => $name,
        'username_clean'       => $clean,
        'user_regdate'         => $now,
        'user_password'        => '',
        'user_colour'          => $bots_group_colour,
        'user_email'           => '',
        'user_lang'            => $config['default_lang'],
        'user_style'           => $config['default_style'],
        'user_timezone'        => 0,
        'user_dateformat'      => $config['default_dateformat'],
        'user_allow_massemail' => 0,
    );

    $user_id = user_add($user_row);
    if (!$user_id) {
        print 'the member was not created for ' . $name . PHP_EOL;
        exit(1);
    }

    // The membership of the BOTS group.
    $conn->query("INSERT INTO phpbb_user_group (group_id, user_id, group_leader, user_pending, auto_group)
      VALUES ($bots_group_id, $user_id, 0, 0, 0)");

    // The bot row.
    $conn->query("INSERT INTO phpbb_bots (bot_active, bot_name, user_id, bot_agent, bot_ip)
      VALUES (1, '" . $conn->real_escape_string($name) . "', $user_id,
              '" . $conn->real_escape_string($agent) . "', '')");

    // The snapshot, so the change can be undone.
    $conn->query("INSERT INTO phpbb_bot_accounts_backup
        (user_id, old_colour, old_group_id, new_colour, new_group_id, the_applied_at)
      VALUES ($user_id, '', 0, '" . $conn->real_escape_string($bots_group_colour) . "',
              $bots_group_id, $now)
      ON DUPLICATE KEY UPDATE
        new_colour = VALUES(new_colour),
        new_group_id = VALUES(new_group_id),
        the_applied_at = VALUES(the_applied_at)");

    $created++;
}

print 'the members created: ' . $created . PHP_EOL . PHP_EOL;

/*
 * Read the result back, from the primary.
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

print 'the bot members now, the colour and the group:' . PHP_EOL;
$result = $primary->query("SELECT u.user_colour, u.group_id, g.group_name, COUNT(*) AS n
   FROM phpbb_users u LEFT JOIN phpbb_groups g ON g.group_id = u.group_id
   WHERE u.user_type = 2 GROUP BY u.user_colour, u.group_id, g.group_name
   ORDER BY n DESC");
while ($row = $result->fetch_array()) {
    printf("  the colour %-10s the group_id %-6s the group %-16s -> %s\n",
        $row[0] === '' ? '(empty)' : $row[0], $row[1], $row[2] === null ? '(none)' : $row[2], $row[3]);
}

$result = $primary->query("SELECT COUNT(*) FROM phpbb_bots");
print 'the bot rows: ' . (int) $result->fetch_row()[0] . PHP_EOL;

$result = $primary->query("SELECT COUNT(*) FROM phpbb_bots b
   WHERE NOT EXISTS (SELECT 1 FROM phpbb_users u WHERE u.user_id = b.user_id)");
print 'the bot rows with no member: ' . (int) $result->fetch_row()[0] . PHP_EOL;

print PHP_EOL . 'the board is updated.' . PHP_EOL;

<?php
/**
 * =====================================================================
 * Repair the administration panel module tree.
 * =====================================================================
 *
 * The recovered board came from two backups that were merged without
 * rebuilding the module tree. The result is that:
 *
 *   1. Fifteen module rows belong to extensions that are not
 *      installed. Clicking them gives a 503, because phpBB looks for
 *      a PHP file that is not on disk.
 *
 *   2. The left_id and right_id values collide. The old extensions
 *      were inserted with left_id and right_id values that other
 *      rows already use, so ten values are used twice. phpBB reads
 *      the tree with a nested set query, so the collisions make the
 *      tree unreadable.
 *
 *   3. Five rows sit outside the range of their parent, so phpBB
 *      cannot find them when it walks the tree.
 *
 * The script removes the dead rows and rebuilds the left_id and
 * right_id values from the parent/child relations, which are intact.
 *
 * The AutoGroups module row is KEPT. The AutoGroups extension is
 * not installed, so the row is inert, but the configuration that
 * goes with it is being kept, and the row comes back with the
 * extension.
 *
 * The script runs inside the phpbb-app container, which has the
 * PHP 8 compatible dependencies that the phpBB 3.3.19 release needs.
 *
 * Usage:
 *   docker exec phpbb-app php /tmp/repair-acp-modules.php
 * =====================================================================
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

/**
 * The module rows to remove, by basename.
 *
 * Every one of these belongs to an extension that is not installed.
 * The list is explicit, so a new extension that is installed later is
 * not removed by accident.
 */
$dead_basenames = array(
    'ads',       // The advertisement manager.
    'styles',   // The style components (templates, themes, imagesets).
    'reimg',    // The re-image extension.
    'mobiquo',  // The Mobiquo/Tapatalk app integration.
    'mods',     // The automod installer.
);

/**
 * The categories to remove, by language name.
 *
 * These are the categories that the removed extensions created. The
 * extension that is not installed cannot add them back, and phpBB
 * skips a category that has no members on the way down.
 */
$dead_categories = array(
    'ACP_STYLE_COMPONENTS',  // The styles extension.
    'ACP_CAT_REIMG',         // The re-image extension.
    'ACP_MOBIQUO',           // The Mobiquo/Tapatalk extension.
    'ACP_CAT_MODS',          // The automod extension.
    'ACP_MODS',              // The automod extension.
);

/**
 * The module rows to keep, even when the extension is not installed.
 *
 * The AutoGroups extension is not installed, but its configuration is
 * being kept, and its module row comes back with the extension.
 */
$keep_basenames = array(
    '\\phpbb\\autogroups\\acp\\autogroups_module',
    '\\phpbb\\viglink\\acp\\viglink_module',
);

// --- 1. The current tree ------------------------------------------------

$sql = 'SELECT module_id, module_langname, module_basename, module_mode,
               parent_id, left_id, right_id
        FROM ' . $table_prefix . 'modules
        WHERE module_class = \'acp\'
        ORDER BY left_id, module_id';
$result = $db->sql_query($sql);
$rows = $db->sql_fetchrowset($result);
$db->sql_freeresult($result);

echo '  the ACP module rows: ' . count($rows) . "\n";

$by_id = array();
$children = array();
foreach ($rows as $row) {
    $row['module_id'] = (int) $row['module_id'];
    $row['parent_id'] = (int) $row['parent_id'];
    $row['left_id'] = (int) $row['left_id'];
    $row['right_id'] = (int) $row['right_id'];
    $by_id[$row['module_id']] = $row;
    $children[$row['parent_id']][] = $row['module_id'];
}

// The duplicate left_id and right_id values.
$lefts = array();
$rights = array();
foreach ($rows as $row) {
    $lefts[$row['left_id']] = true;
    $rights[$row['right_id']] = true;
}
$duplicates = count($rows) - count($lefts);
echo '  the duplicate left_id values: ' . $duplicates . "\n";

// --- 2. The rows to remove -----------------------------------------------

$removal = array();

foreach ($rows as $row) {
    if (in_array($row['module_langname'], $dead_categories, true)) {
        $removal[$row['module_id']] = $row;
        continue;
    }
    if ($row['module_basename'] === '' || $row['module_basename'] === null) {
        continue;
    }
    if (in_array($row['module_basename'], $keep_basenames, true)) {
        continue;
    }
    if (in_array($row['module_basename'], $dead_basenames, true)) {
        $removal[$row['module_id']] = $row;
    }
}

// A category whose children are all removed goes too, because phpBB
// skips a category that has no members on the way down.
$changed = true;
while ($changed) {
    $changed = false;
    foreach ($rows as $row) {
        if (isset($removal[$row['module_id']]) || $row['module_basename'] !== '') {
            continue;
        }
        $kids = isset($children[$row['module_id']]) ? $children[$row['module_id']] : array();
        if (!$kids) {
            continue;
        }
        $all_removed = true;
        foreach ($kids as $kid) {
            if (!isset($removal[$kid])) {
                $all_removed = false;
                break;
            }
        }
        if ($all_removed) {
            $removal[$row['module_id']] = $row;
            $changed = true;
        }
    }
}

// A row whose parent is removed is re-parented to the removed
// parent's parent, so that nothing is orphaned.
$reparent = array();
foreach ($rows as $row) {
    if (isset($removal[$row['module_id']])) {
        continue;
    }
    $parent = $row['parent_id'];
    $guard = 0;
    while (isset($removal[$parent]) && $guard < 20) {
        $parent = $removal[$parent]['parent_id'];
        $guard++;
    }
    if ($parent != $row['parent_id']) {
        $reparent[$row['module_id']] = $parent;
    }
}

echo '  the rows to remove: ' . count($removal) . "\n";
foreach ($removal as $row) {
    echo '    - ' . $row['module_langname'] . ' (' . $row['module_basename'] . ")\n";
}
echo '  the rows to re-parent: ' . count($reparent) . "\n";

// --- 3. The removal ------------------------------------------------------

if ($removal) {
    $ids = implode(',', array_keys($removal));
    $db->sql_query('DELETE FROM ' . $table_prefix . 'modules
                    WHERE module_class = \'acp\'
                    AND module_id IN (' . $ids . ')');
    echo "  the dead module rows have been removed\n";
}

foreach ($reparent as $module_id => $parent_id) {
    $db->sql_query('UPDATE ' . $table_prefix . 'modules
                    SET parent_id = ' . (int) $parent_id . '
                    WHERE module_id = ' . (int) $module_id);
}
if ($reparent) {
    echo "  the orphaned module rows have been re-parented\n";
}

// --- 3b. The corrupted parent links --------------------------------------
//
// Two rows name a parent that they do not sit inside. The stock
// board shows where they belong.
//
//   ACP_PRUNE_USERS (714) names ACP_USER_SECURITY (623), but it
//   sits at 155..156, which is inside ACP_CAT_USERS (621). The
//   stock board puts it under ACP_CAT_USERS as well.
//
//   ACP_LANGUAGE_PACKS (678) names ACP_GENERAL_TASKS (637), but it
//   sits at 243..244, which is inside ACP_LANGUAGE (890). The stock
//   board puts it under ACP_LANGUAGE as well.
$fix_parents = array(
    714 => 621,   // ACP_PRUNE_USERS   -> ACP_CAT_USERS
    678 => 890,   // ACP_LANGUAGE_PACKS -> ACP_LANGUAGE
);

foreach ($fix_parents as $module_id => $parent_id) {
    $db->sql_query('UPDATE ' . $table_prefix . 'modules
                    SET parent_id = ' . (int) $parent_id . '
                    WHERE module_class = \'acp\'
                    AND module_id = ' . (int) $module_id);
}
echo '  the corrupted parent links have been repaired: ' . count($fix_parents) . "\n";

// --- 4. The rebuild ------------------------------------------------------

// The tree is rebuilt with the parent/child relations, which are
// intact. A depth first walk gives every row a left_id and a
// right_id that enclose its whole branch.
$sql = 'SELECT module_id, parent_id FROM ' . $table_prefix . 'modules
        WHERE module_class = \'acp\'
        ORDER BY left_id, module_id';
$result = $db->sql_query($sql);
$rows = $db->sql_fetchrowset($result);
$db->sql_freeresult($result);

$by_id = array();
$children = array();
foreach ($rows as $row) {
    $row['module_id'] = (int) $row['module_id'];
    $row['parent_id'] = (int) $row['parent_id'];
    $row['new_left_id'] = 0;
    $row['new_right_id'] = 0;
    $by_id[$row['module_id']] = $row;
    $children[$row['parent_id']][] = $row['module_id'];
}

$counter = 0;

/**
 * Walk the tree, giving each row its left_id and right_id.
 */
$walk = function ($parent_id) use (&$walk, &$counter, &$children, &$by_id) {
    if (!isset($children[$parent_id])) {
        return;
    }
    foreach ($children[$parent_id] as $module_id) {
        $counter++;
        $by_id[$module_id]['new_left_id'] = $counter;
        $walk($module_id);
        $counter++;
        $by_id[$module_id]['new_right_id'] = $counter;
    }
};

$walk(0);

// Any row that is not reachable from the root is given a place at
// the end, so that it is not left with a left_id of zero.
foreach ($by_id as $module_id => $row) {
    if ($row['new_left_id'] === 0) {
        $counter++;
        $by_id[$module_id]['new_left_id'] = $counter;
        $counter++;
        $by_id[$module_id]['new_right_id'] = $counter;
    }
}

$db->sql_query('BEGIN');
foreach ($by_id as $module_id => $row) {
    $db->sql_query('UPDATE ' . $table_prefix . 'modules
                    SET left_id = ' . (int) $row['new_left_id'] . ',
                        right_id = ' . (int) $row['new_right_id'] . '
                    WHERE module_id = ' . (int) $module_id);
}
$db->sql_query('COMMIT');

echo "  the nested set has been rebuilt\n";

// --- 5. The check --------------------------------------------------------

$sql = 'SELECT module_id, parent_id, left_id, right_id FROM ' . $table_prefix . 'modules
        WHERE module_class = \'acp\'
        ORDER BY left_id, module_id';
$result = $db->sql_query($sql);
$rows = $db->sql_fetchrowset($result);
$db->sql_freeresult($result);

$lefts = array();
$rights = array();
foreach ($rows as $row) {
    $lefts[(int) $row['left_id']] = true;
    $rights[(int) $row['right_id']] = true;
}

$problems = 0;
if (count($lefts) !== count($rows) || count($rights) !== count($rows)) {
    echo "  ERROR: the left_id and right_id values still collide\n";
    $problems++;
}

$by_id = array();
foreach ($rows as $row) {
    $by_id[(int) $row['module_id']] = $row;
}
foreach ($by_id as $module_id => $row) {
    $parent = (int) $row['parent_id'];
    if ($parent && isset($by_id[$parent])) {
        $p = $by_id[$parent];
        if (!((int) $p['left_id'] < (int) $row['left_id'] && (int) $row['right_id'] < (int) $p['right_id'])) {
            echo '  ERROR: the row ' . $module_id . ' sits outside its parent' . "\n";
            $problems++;
        }
    }
}

echo '  the ACP module rows: ' . count($rows) . "\n";
echo '  the problems: ' . $problems . "\n";

exit($problems === 0 ? 0 : 1);

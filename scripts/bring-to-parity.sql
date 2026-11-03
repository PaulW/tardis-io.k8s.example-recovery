-- =====================================================================
-- Bring the recovered forum to 1:1 parity with a stock phpBB 3.3.19.
-- =====================================================================
-- The recovered board came out of the 2016 backup, so it had the 3.1
-- schema, the MyISAM engine, and the columns of the extensions the
-- old board had.
--
-- This script is the change that was applied on 24 October 2026. It
-- was proved first, on a complete copy of the board, and the plan is
-- in backup_recover/PARITY-PLAN.md.
--
-- The script is idempotent in the sense that running it twice is
-- harmless for the steps that are guarded, but the index steps will
-- fail the second time because the index is already there. It is
-- meant to be run once, against a database that is in the state the
-- recovery left it in.
--
-- Usage:
--   mariadb -u root -p phpbb < bring-to-parity.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The indexes that phpBB creates and the recovered board did not.
-- ---------------------------------------------------------------------
-- phpbb_posts.post_username. The board shows 21,064 posts under a
-- placeholder name, and search.php looks posts up by that name.
-- Without the index, that is a full table scan across 125,622 posts.
ALTER TABLE phpbb_posts   ADD INDEX `post_username` (`post_username`);

-- phpbb_reports.post_id and phpbb_reports.pm_id.
ALTER TABLE phpbb_reports ADD INDEX `post_id` (`post_id`);
ALTER TABLE phpbb_reports ADD INDEX `pm_id` (`pm_id`);

-- phpbb_bookmarks has the columns as a plain index named
-- topic_user_id. phpBB creates them as the primary key, so the plain
-- index goes and the primary key comes.
ALTER TABLE phpbb_bookmarks DROP INDEX `topic_user_id`;
ALTER TABLE phpbb_bookmarks ADD PRIMARY KEY (`topic_id`, `user_id`);

-- phpbb_search_wordmatch has two unique indexes on the same three
-- columns. The one phpBB creates is un_mtch, so unq_mtch goes.
ALTER TABLE phpbb_search_wordmatch DROP INDEX `unq_mtch`;

-- ---------------------------------------------------------------------
-- 2. The table options that phpBB creates and the recovered board
--    did not.
-- ---------------------------------------------------------------------
-- The collation. phpBB uses utf8mb3_bin, which is case sensitive, so
-- two values that differ only in their case are different values.
-- The table collation was the wrong one on 11 tables.
ALTER TABLE phpbb_config_text            COLLATE utf8mb3_bin;
ALTER TABLE phpbb_ext                    COLLATE utf8mb3_bin;
ALTER TABLE phpbb_migrations             COLLATE utf8mb3_bin;
ALTER TABLE phpbb_notifications          COLLATE utf8mb3_bin;
ALTER TABLE phpbb_notification_types     COLLATE utf8mb3_bin;
ALTER TABLE phpbb_oauth_accounts         COLLATE utf8mb3_bin;
ALTER TABLE phpbb_oauth_tokens           COLLATE utf8mb3_bin;
ALTER TABLE phpbb_teampage               COLLATE utf8mb3_bin;
ALTER TABLE phpbb_user_notifications     COLLATE utf8mb3_bin;
ALTER TABLE phpbb_recovered_topic_titles COLLATE utf8mb3_bin;
ALTER TABLE phpbb_auth_provider_oauth    COLLATE utf8mb3_bin;

-- The row format. phpBB uses Dynamic, which does not waste the
-- space of the short rows. MyISAM defaults to Fixed.
ALTER TABLE phpbb_acl_groups            ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_acl_roles_data        ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_acl_users              ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_ads_forums            ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_ads_groups            ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_ads_in_positions      ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_bookmarks             ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_forums_access         ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_forums_track          ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_forums_watch          ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_garage_dynoruns_gallery      ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_garage_laps_gallery          ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_garage_modifications_gallery ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_garage_quartermiles          ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_garage_quartermiles_gallery  ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_garage_ratings                ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_garage_service_history        ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_garage_vehicles_gallery       ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_privmsgs_to         ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_search_wordmatch    ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_tapatalk_users      ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_topics_posted       ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_topics_track        ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_topics_watch        ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_user_group          ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_warnings            ROW_FORMAT=DYNAMIC;
ALTER TABLE phpbb_zebra               ROW_FORMAT=DYNAMIC;

-- ---------------------------------------------------------------------
-- 3. The columns whose type, nullability or default differs.
-- ---------------------------------------------------------------------
-- The small integers. tinyint(1) is one byte whether it is signed
-- or not, so this changes the range and nothing else.
ALTER TABLE phpbb_ext                MODIFY ext_active TINYINT(1) UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE phpbb_migrations         MODIFY migration_schema_done TINYINT(1) UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE phpbb_migrations         MODIFY migration_data_done TINYINT(1) UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE phpbb_migrations         MODIFY migration_start_time INT(11) UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE phpbb_migrations         MODIFY migration_end_time INT(11) UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE phpbb_notification_types MODIFY notification_type_enabled TINYINT(1) UNSIGNED NOT NULL DEFAULT 1;
ALTER TABLE phpbb_notifications      MODIFY notification_read TINYINT(1) UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE phpbb_notifications      MODIFY notification_time INT(11) UNSIGNED NOT NULL DEFAULT 1;
ALTER TABLE phpbb_user_notifications MODIFY notify TINYINT(1) UNSIGNED NOT NULL DEFAULT 1;

-- The ids. The recovered ones are int(10) and the stock ones are
-- mediumint(8). The tables are empty, so nothing is at risk.
ALTER TABLE phpbb_notifications      MODIFY item_id MEDIUMINT(8) UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE phpbb_notifications      MODIFY item_parent_id MEDIUMINT(8) UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE phpbb_teampage           MODIFY group_id MEDIUMINT(8) UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE phpbb_teampage           MODIFY teampage_parent MEDIUMINT(8) UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE phpbb_teampage           MODIFY teampage_position MEDIUMINT(8) UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE phpbb_notification_types MODIFY notification_type_id SMALLINT(4) UNSIGNED NOT NULL AUTO_INCREMENT;
ALTER TABLE phpbb_notifications      MODIFY notification_type_id SMALLINT(4) UNSIGNED NOT NULL DEFAULT 0;

-- phpbb_styles.style_parent_id. The recovered one is mediumint(8)
-- and the stock one is int(4). The table holds one row.
ALTER TABLE phpbb_styles              MODIFY style_parent_id INT(4) UNSIGNED NOT NULL DEFAULT 0;

-- phpbb_oauth_tokens.session_id. The recovered one is text and the
-- stock one is char(32). The table is empty.
ALTER TABLE phpbb_oauth_tokens        MODIFY session_id CHAR(32) NOT NULL DEFAULT '';

-- The nullability and the defaults. None of these columns hold a
-- null, so nothing is lost.
ALTER TABLE phpbb_config_text         MODIFY config_name VARCHAR(255) NOT NULL DEFAULT '';
ALTER TABLE phpbb_config_text         MODIFY config_value MEDIUMTEXT NOT NULL;
ALTER TABLE phpbb_ext                 MODIFY ext_name VARCHAR(255) NOT NULL DEFAULT '';
ALTER TABLE phpbb_migrations          MODIFY migration_name VARCHAR(255) NOT NULL DEFAULT '';
ALTER TABLE phpbb_notifications       MODIFY notification_data TEXT NOT NULL;
ALTER TABLE phpbb_oauth_accounts      MODIFY oauth_provider_id TEXT NOT NULL;
ALTER TABLE phpbb_oauth_accounts      MODIFY provider VARCHAR(255) NOT NULL DEFAULT '';
ALTER TABLE phpbb_oauth_tokens        MODIFY oauth_token MEDIUMTEXT NOT NULL;
ALTER TABLE phpbb_oauth_tokens        MODIFY provider VARCHAR(255) NOT NULL DEFAULT '';
ALTER TABLE phpbb_styles              MODIFY style_copyright VARCHAR(255) NOT NULL DEFAULT '';
ALTER TABLE phpbb_styles              MODIFY style_name VARCHAR(255) NOT NULL DEFAULT '';
ALTER TABLE phpbb_users               MODIFY user_avatar VARCHAR(255) NOT NULL DEFAULT '';

-- The column collations.
ALTER TABLE phpbb_config_text         MODIFY config_name VARCHAR(255) NOT NULL DEFAULT '' COLLATE utf8mb3_bin;
ALTER TABLE phpbb_config_text         MODIFY config_value MEDIUMTEXT NOT NULL COLLATE utf8mb3_bin;
ALTER TABLE phpbb_ext                 MODIFY ext_name VARCHAR(255) NOT NULL DEFAULT '' COLLATE utf8mb3_bin;
ALTER TABLE phpbb_ext                 MODIFY ext_state TEXT NOT NULL COLLATE utf8mb3_bin;
ALTER TABLE phpbb_migrations          MODIFY migration_name VARCHAR(255) NOT NULL DEFAULT '' COLLATE utf8mb3_bin;
ALTER TABLE phpbb_migrations          MODIFY migration_depends_on TEXT NOT NULL COLLATE utf8mb3_bin;
ALTER TABLE phpbb_migrations          MODIFY migration_data_state TEXT NOT NULL COLLATE utf8mb3_bin;
ALTER TABLE phpbb_notification_types  MODIFY notification_type_name VARCHAR(255) NOT NULL DEFAULT '' COLLATE utf8mb3_bin;
ALTER TABLE phpbb_notifications       MODIFY notification_data TEXT NOT NULL COLLATE utf8mb3_bin;
ALTER TABLE phpbb_oauth_accounts      MODIFY provider VARCHAR(255) NOT NULL DEFAULT '' COLLATE utf8mb3_bin;
ALTER TABLE phpbb_oauth_accounts      MODIFY oauth_provider_id TEXT NOT NULL COLLATE utf8mb3_bin;
ALTER TABLE phpbb_oauth_tokens        MODIFY provider VARCHAR(255) NOT NULL DEFAULT '' COLLATE utf8mb3_bin;
ALTER TABLE phpbb_oauth_tokens        MODIFY session_id CHAR(32) NOT NULL DEFAULT '' COLLATE utf8mb3_bin;
ALTER TABLE phpbb_oauth_tokens        MODIFY oauth_token MEDIUMTEXT NOT NULL COLLATE utf8mb3_bin;
ALTER TABLE phpbb_teampage            MODIFY teampage_name VARCHAR(255) NOT NULL DEFAULT '' COLLATE utf8mb3_bin;
ALTER TABLE phpbb_user_notifications  MODIFY item_type VARCHAR(165) NOT NULL DEFAULT '' COLLATE utf8mb3_bin;
ALTER TABLE phpbb_user_notifications  MODIFY method VARCHAR(165) NOT NULL DEFAULT '' COLLATE utf8mb3_bin;

-- phpbb_posts.post_text. The recovered board has the Unicode
-- collation, which phpBB 3.1 used, and phpBB 3.3 has the binary
-- one. The column is in no index, so nothing is keyed on it and the
-- change cannot lose a row.
ALTER TABLE phpbb_posts              MODIFY post_text MEDIUMTEXT NOT NULL COLLATE utf8mb3_bin;

-- ---------------------------------------------------------------------
-- 4. The extra tables.
-- ---------------------------------------------------------------------
-- The Tapatalk tables. The push data is the record of what the
-- Tapatalk app was told about, and the users table is the app's
-- per-member settings. Neither is read by phpBB.
DROP TABLE IF EXISTS phpbb_tapatalk_push_data;
DROP TABLE IF EXISTS phpbb_tapatalk_users;

-- The Ads tables.
DROP TABLE IF EXISTS phpbb_ads;
DROP TABLE IF EXISTS phpbb_ads_forums;
DROP TABLE IF EXISTS phpbb_ads_groups;
DROP TABLE IF EXISTS phpbb_ads_in_positions;
DROP TABLE IF EXISTS phpbb_ads_positions;

-- The phpBB Garage tables.
DROP TABLE IF EXISTS phpbb_garage_blog;
DROP TABLE IF EXISTS phpbb_garage_business;
DROP TABLE IF EXISTS phpbb_garage_categories;
DROP TABLE IF EXISTS phpbb_garage_config;
DROP TABLE IF EXISTS phpbb_garage_dynoruns;
DROP TABLE IF EXISTS phpbb_garage_dynoruns_gallery;
DROP TABLE IF EXISTS phpbb_garage_guestbooks;
DROP TABLE IF EXISTS phpbb_garage_images;
DROP TABLE IF EXISTS phpbb_garage_laps;
DROP TABLE IF EXISTS phpbb_garage_laps_gallery;
DROP TABLE IF EXISTS phpbb_garage_makes;
DROP TABLE IF EXISTS phpbb_garage_models;
DROP TABLE IF EXISTS phpbb_garage_modifications;
DROP TABLE IF EXISTS phpbb_garage_modifications_gallery;
DROP TABLE IF EXISTS phpbb_garage_premiums;
DROP TABLE IF EXISTS phpbb_garage_products;
DROP TABLE IF EXISTS phpbb_garage_quartermiles;
DROP TABLE IF EXISTS phpbb_garage_quartermiles_gallery;
DROP TABLE IF EXISTS phpbb_garage_ratings;
DROP TABLE IF EXISTS phpbb_garage_service_history;
DROP TABLE IF EXISTS phpbb_garage_tracks;
DROP TABLE IF EXISTS phpbb_garage_vehicles;
DROP TABLE IF EXISTS phpbb_garage_vehicles_gallery;

-- The CAPTCHA tables, and the QA tables.
DROP TABLE IF EXISTS phpbb_captcha_questions;
DROP TABLE IF EXISTS phpbb_captcha_answers;
DROP TABLE IF EXISTS phpbb_qa_confirm;

-- The OAuth provider table, for an extension that is not installed.
DROP TABLE IF EXISTS phpbb_auth_provider_oauth;

-- ---------------------------------------------------------------------
-- 5. The extra columns.
-- ---------------------------------------------------------------------
-- The phpBB Ads and phpBB Garage columns on phpbb_users. Both
-- extensions held their settings here. Every row holds the default.
ALTER TABLE phpbb_users DROP COLUMN ad_owner;
ALTER TABLE phpbb_users DROP COLUMN user_garage_display_profile;
ALTER TABLE phpbb_users DROP COLUMN user_garage_gb_email_notify;
ALTER TABLE phpbb_users DROP COLUMN user_garage_gb_pm_notify;
ALTER TABLE phpbb_users DROP COLUMN user_garage_index_columns;
ALTER TABLE phpbb_users DROP COLUMN user_garage_mod_email_optout;
ALTER TABLE phpbb_users DROP COLUMN user_garage_mod_pm_optout;
ALTER TABLE phpbb_users DROP COLUMN user_garage_profile_modpic;

-- The AutoGroups columns on phpbb_groups and phpbb_user_group are
-- KEPT, because the AutoGroups extension is going to be used again.
-- The group "CB-UK Standard Member" has group_min_posts = 30 and
-- group_max_days = 30, and 274 of the memberships were placed by
-- AutoGroups rather than by hand.

-- The custom profile field columns are KEPT, because the fields are
-- active and phpBB reads the columns by name. pf_antispam holds
-- 9,269 values, pf_car_owner holds 12,108 and pf_postcode holds
-- 12,099.

-- ---------------------------------------------------------------------
-- 6. The config settings that belong to the removed extensions.
-- ---------------------------------------------------------------------
DELETE FROM phpbb_config WHERE config_name LIKE 'tapatalk%';
DELETE FROM phpbb_config WHERE config_name LIKE 'sitemap_seo%';
DELETE FROM phpbb_config WHERE config_name LIKE 'ads_%';
DELETE FROM phpbb_config WHERE config_name LIKE 'bbgarage%';
DELETE FROM phpbb_config WHERE config_name LIKE 'mobile%';
DELETE FROM phpbb_config WHERE config_name LIKE 'mobiquo%';
DELETE FROM phpbb_config WHERE config_name LIKE 'auth_oauth_%';
DELETE FROM phpbb_config WHERE config_name LIKE 'peoplesign%';

-- The autogroups_last_run setting is KEPT, with the AutoGroups
-- columns.

-- ---------------------------------------------------------------------
-- 7. The engine.
-- ---------------------------------------------------------------------
-- Every table that is MyISAM becomes InnoDB. MyISAM has no crash
-- recovery, so a table that is being written to when the machine
-- goes down can be left with a hole in it, which is what happened
-- in June.
--
-- The list is written out by the script, so it is always the tables
-- that are there:
--
--   mariadb -u root -p -N -e "SELECT CONCAT('ALTER TABLE ',
--     TABLE_NAME, ' ENGINE=InnoDB;') FROM information_schema.TABLES
--     WHERE TABLE_SCHEMA='phpbb' AND ENGINE='MyISAM'
--     AND TABLE_TYPE='BASE TABLE'
--     ORDER BY (DATA_LENGTH+INDEX_LENGTH) DESC;" > innodb.sql
--
--   mariadb -u root -p phpbb < innodb.sql
--
-- The whole conversion takes about two seconds.

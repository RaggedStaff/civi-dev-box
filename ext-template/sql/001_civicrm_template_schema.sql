-- Blank install schema for the Template extension.
--
-- CiviCRM runs this file when the extension is first enabled, and re-runs any
-- newly added numbered *.sql files when it is upgraded. Name them
-- 001_initial.sql, 002_add_widget.sql, ... so the order is explicit.
--
-- Note CiviCRM's database requirements this schema depends on:
--   * no ANSI / ANSI_QUOTES in sql_mode
--   * ONLY_FULL_GROUP_BY disabled
--   * utf8mb4 throughout
--
-- Run `./40-install-extension.sh --sql-only` to apply pending changes after
-- editing this file.

CREATE TABLE IF NOT EXISTS `civicrm_template_note` (
  `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `subject`     VARCHAR(255)     NOT NULL DEFAULT '',
  `body`        TEXT                 NULL,
  `created_at`  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `is_active`   TINYINT(1)      NOT NULL DEFAULT 1,
  PRIMARY KEY (`id`),
  KEY `is_active` (`is_active`),
  KEY `created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

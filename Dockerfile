# =============================================================================
# civi-dev-box  --  custom application image
# =============================================================================
# Built FROM the official CiviCRM base image. That image already satisfies
# everything this platform fought us over:
#
#   Debian 12 (bookworm) and amd64, so it is inside the platform's supported
#     base-OS allowlist (AlmaLinux 9, Alpine 3, CentOS 7/8, Debian 12,
#     Ubuntu 18.04-24.04). The stock `php:8.5-apache` is Debian 13 and is not.
#   PHP 8.5.11, which is what the extension and CiviCRM 6.16+ both pair with.
#   intl compiled in - the one extension stock php images omit, and the one
#     CiviCRM refuses to run without.
#   DocumentRoot /var/www/html and AllowOverride All, so .htaccess is honoured.
#   No site-wide HTTP Basic Auth.
#   cv on PATH, and a MariaDB client for 11-db-bootstrap.sh.
#
# Six import failures came from properties of the platform's certified PHP image
# rather than from anything in this repo: intl shipped disabled, a syntax error
# at line 688 of the provider's php.ini silently discarded every later setting,
# `php --ini` printed quoted paths that a naive parser captured verbatim, the
# document root was not where we assumed, the provider enabled Basic Auth, and
# the platform generates its own database credentials. A custom image removes
# that whole class of problem instead of working around it.
#
# BUILD
#   docker build -t <account>/civi-dev-box:8.5.11 .
#   or: make image-build IMAGE=<account>/civi-dev-box
#
# The RUNTIME is pinned here. Which CiviCRM release is installed is NOT: that
# stays a deployment-time choice in the JPS manifest, so one image serves several
# CiviCRM versions and upgrading the box does not mean rebuilding the image.
# =============================================================================
FROM civicrm/civicrm-base:php8.5

ENV CIVICRM_DOCROOT=/var/www/html \
    CIVICRM_DATA_DIR=/var/lib/civicrm-data \
    DEBIAN_FRONTEND=noninteractive

# =============================================================================
# What this image is missing
#
# cron    - `cv core:job` is inert without it. The crontab entry itself is a
#           manual dashboard step (JPS cannot create one), but cron has to be
#           installed and running for that step to mean anything.
# git     - 20-fetch-civicrm.sh and the extension deploy both use it.
# unzip   - CiviCRM's extension manager expects it.
# composer- not needed by `cv core:install`, but the extension's own tooling
#           uses it and it saves a manual install later.
# =============================================================================
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        cron \
        git \
        unzip \
        ca-certificates \
        procps \
        less \
        vim-tiny \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# =============================================================================
# Persistent volume
#
# private/, public/ and ext/ are symlinked into here by 20-fetch-civicrm.sh, so
# uploads, civicrm.settings.php and installed extensions survive a container
# replacement. owned by www-data because Apache runs as www-data and those trees
# must be writable.
# =============================================================================
RUN set -eux; \
    mkdir -p "$CIVICRM_DATA_DIR" "$CIVICRM_DOCROOT"; \
    chown -R www-data:www-data "$CIVICRM_DATA_DIR"

# =============================================================================
# Never serve private/ or core/
#
# private/ holds civicrm.settings.php, which contains the database credentials.
# These are baked in so they are in place from the first request rather than from
# the first successful provision - and so that a half-provisioned box, which is
# exactly the state a failed import leaves behind, cannot leak them.
#
# Both syntaxes, since we do not control which Apache modules are loaded.
# =============================================================================
RUN set -eux; \
    mkdir -p "$CIVICRM_DOCROOT/private" "$CIVICRM_DOCROOT/core"; \
    for d in private core; do \
        { \
            echo '<IfModule mod_authz_core.c>'; \
            echo '  Require all denied'; \
            echo '</IfModule>'; \
            echo '<IfModule !mod_authz_core.c>'; \
            echo '  Order allow,deny'; \
            echo '  Deny from all'; \
            echo '</IfModule>'; \
        } > "$CIVICRM_DOCROOT/$d/.htaccess"; \
    done

# Defensive: strip any site-wide Basic Auth that a future base image might grow.
# This box has no secrets worth protecting that the deny rules above do not
# already cover, and a 401 on every request is an obstacle, not a safeguard.
RUN set -eux; \
    sed -ri 's/^\s*AuthType\s+Basic/#&/; s/^\s*Require\s+valid-user/#&/' \
        /etc/apache2/sites-available/*.conf /etc/apache2/sites-enabled/*.conf \
        /etc/apache2/conf-enabled/*.conf 2>/dev/null || true; \
    ! grep -rqiE '^\s*(AuthType\s+Basic|Require\s+valid-user)' \
        /etc/apache2/sites-enabled /etc/apache2/conf-enabled \
        || { echo "site-wide Basic Auth is still configured"; exit 1; }

# Silences "could not reliably determine the server's fully qualified domain
# name" on every start.
RUN set -eux; \
    echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf; \
    a2enconf servername >/dev/null

# =============================================================================
# Cron
#
# The official base image has no init system, so a unit file does nothing. Start
# it alongside Apache by replacing the CMD below instead.
# =============================================================================
RUN set -eux; \
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '# Managed by civi-dev-box: run Apache in the foreground (the image' \
        '# default) and cron alongside it, because this image has no init.' \
        'set -e' \
        'cron' \
        'exec apache2-foreground' \
        > /usr/local/bin/civi-foreground; \
    chmod +x /usr/local/bin/civi-foreground

CMD ["civi-foreground"]

# =============================================================================
# Build-time verification
#
# Fail the BUILD rather than the deployment. Every previous version of this box
# discovered a missing requirement only after an environment had already been
# created - a 5-minute round trip per bug.
#
# Mirrors CIVICRM_REQUIRED_EXTENSIONS in scripts/lib.sh, plus the tools the
# provisioning hooks invoke.
# =============================================================================
RUN set -eux; \
    for ext in bcmath curl dom mbstring zip intl fileinfo pdo_mysql; do \
        php -m | tr 'A-Z' 'a-z' | grep -qx "$ext" \
            || { echo "MISSING required PHP extension: $ext"; exit 1; }; \
    done; \
    php -r 'exit(version_compare(PHP_VERSION, "8.2", ">=") ? 0 : 1);' \
        || { echo "PHP is below the 8.2 minimum"; exit 1; }; \
    for tool in cv mysql mariadb cron git unzip composer; do \
        command -v "$tool" >/dev/null || { echo "MISSING required tool: $tool"; exit 1; }; \
    done; \
    grep -q "DocumentRoot ${CIVICRM_DOCROOT}" /etc/apache2/sites-enabled/000-default.conf \
        || { echo "unexpected DocumentRoot"; exit 1; }; \
    grep -q '^  Require all denied' "${CIVICRM_DOCROOT}/private/.htaccess" \
        || { echo "private/ is not protected"; exit 1; }; \
    php -v | head -1; \
    echo "--- image verification passed ---"
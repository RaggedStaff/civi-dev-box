# =============================================================================
# civi-dev-box  --  drive the box and the extension
# =============================================================================
# Two halves:
#   * box      : the Jelastic environment (manifest deploy + remote scripts)
#   * ext      : the dfc_civicrm extension, built and shipped as an archive
#
# The extension half deliberately delegates to the extension's OWN tools
# (tools/preflight.sh, tools/build-release.sh, tools/verify-install.sh) rather
# than reimplementing them. Those scripts are the acceptance criteria; this
# Makefile just moves the artifact onto the box.
#
#   make help
# =============================================================================

SHELL     := /bin/bash
SCRIPTS   ?= scripts
TARGET    ?= civi-dev
SSH_USER  ?= root
SSH_KEY   ?=
SSH_OPTS  := $(if $(SSH_KEY),-i $(SSH_KEY),)
SSH       := $(SSH_OPTS) $(SSH_USER)@$(TARGET)

# The extension under test. Override if it moves.
EXT_DIR   ?= /home/raggedstaff/gitrepos/The-Mansion/projects/dfc-civicrm-v2/dfc_civicrm
EXT_KEY   ?= dfc_civicrm
SITE_URL  ?= https://dev.civi.sioldata.com

export CIVICRM_DATA_DIR ?= /var/lib/civicrm-data
export CIVICRM_EXT_KEY   := $(EXT_KEY)

.DEFAULT_GOAL := help
.PHONY: help

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  EXT_DIR=$(EXT_DIR)"
	@echo "  TARGET=$(TARGET)  SITE_URL=$(SITE_URL)"

# =============================================================================
# EXTENSION  (runs on your workstation)
# =============================================================================
.PHONY: ext-preflight
ext-preflight: ## Run the extension's own tools/preflight.sh (no box needed)
	cd "$(EXT_DIR)" && ./tools/preflight.sh

.PHONY: ext-test
ext-test: ## Run the extension's unit suite
	cd "$(EXT_DIR)" && ./vendor/bin/phpunit --testsuite unit

.PHONY: ext-git-install
ext-git-install: ## Clone dfc_civicrm, build the release on the box, and deploy it
	$(SSHRUN) $(SCRIPTS)/45-build-from-git.sh

.PHONY: ext-build
ext-build: ## Build the release archive into $(EXT_DIR)/build
	cd "$(EXT_DIR)" && ./tools/build-release.sh --force
	@echo ""
	@echo "  built:"
	@ls -1sh "$(EXT_DIR)"/build/*/*.tar.gz 2>/dev/null | sed 's/^/    /'

.PHONY: ext-push
ext-push: ## Copy the built archive to the box
	@set -e; \
	archive=$$(ls -1 "$(EXT_DIR)"/build/*/*.tar.gz | tail -1); \
	echo "  pushing $$(basename $$archive)"; \
	scp $(SSH_OPTS) "$$archive" "$(SSH):$(CIVICRM_DATA_DIR)/"; \
	$(SSH) 'ls -lh $(CIVICRM_DATA_DIR)/*.tar.gz' | sed 's/^/    /'

.PHONY: ext-install
ext-install: ## Install the pushed archive on the box (upload if missing)
	@set -e; \
	archive=$$(ls -1 "$(EXT_DIR)"/build/*/*.tar.gz | tail -1); \
	scp $(SSH_OPTS) -q "$$archive" "$(SSH):$(CIVICRM_DATA_DIR)/"; \
	$(SSH) "CIVICRM_DATA_DIR=$(CIVICRM_DATA_DIR) bash $(CIVICRM_DATA_DIR)/deploy-archive.sh '$$(basename $$archive)'"

# Copies the deploy script onto the box and runs it with the archive.
# Kept as a file rather than piping so the same command works over SSH later.
.PHONY: ext-install-push
ext-install-push: ext-build ext-push ## build + copy only (install via SSH by hand)
	$(SSH) 'true'

.PHONY: ext-sql
ext-sql: ## Apply pending extension DB migrations on the box
	$(SSH) "CIVICRM_DATA_DIR=$(CIVICRM_DATA_DIR) bash $(CIVICRM_DATA_DIR)/deploy-archive.sh --sql-only"

.PHONY: ext-disable
ext-disable: ## Disable the extension on the box
	$(SSH) 'cv ext:disable $(EXT_KEY)'

.PHONY: ext-enable
ext-enable: ## Re-enable the extension on the box
	$(SSH) 'cv ext:enable $(EXT_KEY)'

.PHONY: ext-verify
ext-verify: ## Run the extension's own tools/verify-install.sh ON the box
	$(SSH) "cd $(CIVICRM_DATA_DIR)/ext/$(EXT_KEY) && ./tools/verify-install.sh --cv $$(command -v cv) --base-url http://localhost"

.PHONY: ext-status
ext-status: ## Show the extension's status on the box
	$(SSH) 'cv ext:status $(EXT_KEY)'

# =============================================================================
# BOX  (runs on the box)
# =============================================================================
# NOTE: every "run a script on the box" target goes through ssh-run.sh, which
# pushes the script and executes it as a FILE.
#
# The obvious alternative - `ssh host 'bash -s' < script.sh` - pipes the script
# into bash's stdin, and a script read from stdin has no BASH_SOURCE. Every
# script's `. lib.sh` line then resolves to "/lib.sh" and the run dies with
# "BASH_SOURCE[0]: unbound variable". That is the same failure that stopped
# every JPS import until the hooks were changed to download to disk, and it was
# still sitting in these four targets.
SSHRUN = CIVICRM_SSH_TARGET=$(TARGET) CIVICRM_SSH_USER=$(SSH_USER) CIVICRM_SSH_KEY=$(SSH_KEY) bash $(SCRIPTS)/ssh-run.sh

.PHONY: preflight
preflight: ## Verify the PHP runtime against CiviCRM's requirements
	$(SSHRUN) $(SCRIPTS)/00-preflight.sh


.PHONY: fetch
fetch: ## Re-materialise the release code and bind volumes
	$(SSHRUN) $(SCRIPTS)/20-fetch-civicrm.sh

.PHONY: install
install: ## Run the non-interactive CiviCRM installer (idempotent)
	$(SSHRUN) $(SCRIPTS)/30-install-civicrm.sh

# Re-point an installed site at another host. The base URL is baked into
# civicrm.settings.php in seven places; updating only one leaves the assets on
# the old host, which a browser refuses when the certificate does not match.
# See 36-set-base-url.sh.
.PHONY: set-base-url
set-base-url: ## Re-point the site: make set-base-url URL=https://host
	@[ -n "$(URL)" ] || { echo "usage: make set-base-url URL=https://host"; exit 1; }
	$(SSHRUN) "CIVICRM_SITE_URL='$(URL)' $(SCRIPTS)/36-set-base-url.sh"

.PHONY: health
health: ## Full healthcheck: runtime, layout, DB, extension, cron
	$(SSHRUN) $(SCRIPTS)/90-healthcheck.sh

.PHONY: why-502
why-502: ## Find out whether anything is serving, and on which port
	$(SSHRUN) $(SCRIPTS)/98-why-502.sh

.PHONY: start-web
start-web: ## Start Apache and cron (the platform replaces the image's CMD)
	$(SSHRUN) $(SCRIPTS)/15-start-web.sh

.PHONY: why-installer
why-installer: ## Why is the site showing the installer instead of the login page?
	$(SSHRUN) $(SCRIPTS)/97-why-installer.sh

# /civicrm/login 404s while / returns 200. Every other check probes a URL that
# needs no rewriting, so only this one can see a lost front controller.
.PHONY: why-routing
why-routing: ## Why does /civicrm/login 404 while / returns 200?
	$(SSHRUN) $(SCRIPTS)/96-why-routing.sh

# Repair for a .htaccess whose rewrite rules were destroyed by an older
# 20-fetch-civicrm.sh. Fetches the authentic file from the release tarball and
# re-merges the civi-dev-box block on top.
.PHONY: restore-htaccess
restore-htaccess: ## Put back the release's .htaccess if its rewrite rules were lost
	$(SSHRUN) $(SCRIPTS)/26-restore-htaccess.sh

# Re-run provisioning on the EXISTING box, without deleting and re-importing.
# The fast iteration loop: fix a script, `make provision`, keep the volumes,
# the database and the uploaded extension archive.
.PHONY: provision
provision: ## Re-run all provisioning steps on the existing box (no re-import)
	$(SSHRUN) $(SCRIPTS)/00-preflight.sh
	$(SSHRUN) $(SCRIPTS)/15-start-web.sh
	$(SSHRUN) $(SCRIPTS)/20-fetch-civicrm.sh
	$(SSHRUN) $(SCRIPTS)/30-install-civicrm.sh
	$(MAKE) --no-print-directory health

.PHONY: up
up: provision ## alias for provision

.PHONY: push-scripts
push-scripts: ## Copy the deploy scripts onto the box
	scp $(SSH_OPTS) $(SCRIPTS)/45-deploy-archive.sh $(SSH):$(CIVICRM_DATA_DIR)/deploy-archive.sh
	scp $(SSH_OPTS) $(SCRIPTS)/lib.sh $(SSH):$(CIVICRM_DATA_DIR)/lib.sh

.PHONY: logs
logs: ## Tail the CiviCRM log
	$(SSH) 'find $(CIVICRM_DATA_DIR)/private/log -name "*.log" -exec tail -f {} +'

# The database and app user are created by the official mariadb image itself,
# from MARIADB_DATABASE / _USER / _PASSWORD in the manifest. There is no bootstrap
# step to run.
#
# What is left is administering it by hand, which needs the DB node's SSH address
# (shown on that node's page in the dashboard) and the dbRootPass setting.
DB_TARGET ?= $(TARGET)-db
DB_ROOT_PASS ?=

.PHONY: db
db: ## Open a MySQL client on the CiviCRM database
	$(SSH) 'mysql -u civicrm -p"$$CIVICRM_DB_PASS" civicrm'

.PHONY: db-root
db-root: ## Open a MySQL client as root (set DB_TARGET and DB_ROOT_PASS)
	@test -n "$(DB_TARGET)" || { echo "Set DB_TARGET to the database node's SSH address"; exit 1; }
	@test -n "$(DB_ROOT_PASS)" || { echo "Set DB_ROOT_PASS to the dbRootPass setting from the manifest"; exit 1; }
	CIVICRM_SSH_TARGET=$(DB_TARGET) CIVICRM_SSH_USER=$(SSH_USER) CIVICRM_SSH_KEY=$(SSH_KEY) \
	  bash -c 'ssh ${0} "mysql -u root -p\"\$1\""' "$(SSH_USER)@$(DB_TARGET)" "$(DB_ROOT_PASS)"

.PHONY: sql
sql: ## Run a query: make sql Q="SELECT COUNT(*) FROM civicrm_contact"
	$(SSH) 'mysql -u civicrm -p"$$CIVICRM_DB_PASS" civicrm -e "$(Q)"'

.PHONY: shell
shell: ## Interactive SSH into the box
	$(SSH)

# =============================================================================
# IMAGE
#
# The manifest points its cp node at a custom image, so the image has to exist in
# a registry the platform can pull from BEFORE you import. `make image-push` is
# therefore a prerequisite of a first install, not a convenience.
# =============================================================================
IMAGE        ?= raggedstaff/civi-dev-box
IMAGE_TAG    ?= 8.5.11
IMAGE_REPO   := $(IMAGE):$(IMAGE_TAG)

.PHONY: image-build
image-build: ## Build the application image
	docker build -t "$(IMAGE_REPO)" .
	@echo "  built $(IMAGE_REPO)"

.PHONY: image-push
image-push: ## Push the image so the platform can pull it
	@test -n "$(IMAGE)" || { echo "Set IMAGE to your registry path, e.g. raggedstaff/civi-dev-box"; exit 1; }
	docker push "$(IMAGE_REPO)"
	@echo ""
	@echo "  pushed $(IMAGE_REPO)"
	@echo "  now import the manifest - its appImage field defaults to this."

.PHONY: image-test
image-test: ## Boot the image and check it serves, denies private/, and survives a CMD override
	@bash tests/image-test.sh
	@bash tests/data-dirs-test.sh
	@bash tests/start-web-test.sh
	@bash tests/htaccess-test.sh
	@bash tests/why-installer-test.sh
	@bash tests/read-settings-test.sh
	@bash tests/build-from-git-test.sh

# =============================================================================
# MANIFEST DEPLOY
# =============================================================================
.PHONY: deploy
deploy: ## Install the JPS manifest via the Jelastic REST API
	@test -n "$(JPS_URL)" || { echo "Set JPS_URL to the public URL of jps/civi-standalone.jps"; exit 1; }
	@test -n "$(JELASTIC_API)" || { echo "Set JELASTIC_API (e.g. https://app.jpe.infomaniak.com/1.0)"; exit 1; }
	@test -n "$(JELASTIC_SESSION)" || { echo "Set JELASTIC_SESSION to your Jelastic API session token"; exit 1; }
	curl -fsSG "$(JELASTIC_API)/environment/control/importmanifest" \
	  --data-urlencode "session=$(JELASTIC_SESSION)" \
	  --data-urlencode "manifestUrl=$(JPS_URL)" \
	  $(JPS_OPTS)

.PHONY: validate
validate: ## Sanity-check the manifest locally
	@python3 -c "import yaml; d=yaml.safe_load(open('jps/civi-standalone.jps')); \
	             f={x['name']: x for x in d['settings']['fields']}; \
	             print('  type    :', d['type']); \
	             print('  images  :', [n['image'] for n in d['nodes']]); \
	             print('  appImage:', f['appImage']['default']); \
	             print('  dbImage :', f['dbImage']['default']); \
	             print('  fields  :', len(d['settings']['fields'])); \
	             print('  events  :', [k for k in d if k.startswith('on')]); \
	             assert all('image' in n and 'nodeType' not in n for n in d['nodes']), \
	               'a node still declares nodeType - custom images should not'; \
	             _bad = [k for n in d['nodes'] for k, v in (n.get('env') or {}).items() \
	                     if '\$${env.' in str(v)]; \
	             assert not _bad, \
	               'node env references \$${env.*}: %s - the env block is evaluated ' \
	               'while the environment is being created, before it has a URL, so ' \
	               'those placeholders never resolve. Pass them in an onInstall cmd.' \
	               % _bad; \
	             _ev = {k.split()[0]: k for k in d if k.startswith('on')}; \
	             _need = ['onInstall', 'onAfterRestartNode', 'onAfterStartNode']; \
	             _missing = [n for n in _need if n not in _ev]; \
	             assert not _missing, \
	               'manifest is missing lifecycle hook(s): %s - a Jelastic environment ' \
	               'that is SUSPENDED and later STARTED fires onAfterStartNode, not ' \
	               'onAfterRestartNode, so without it the node comes back with no web ' \
	               'server at all and only port 22 answering' % _missing; \
	             print('  OK')"
	@# ${env.x} is Jelastic JPS syntax, not bash. Bash rejects a parameter name
	@# containing '.', so ${env.x} is a "bad substitution" the moment it is
	@# evaluated - and it stayed hidden for weeks because bash expands the
	@# fallback of ${a:-${b}} lazily. Only a blank setting reached it, and then a
	@# whole fresh import died in the install hook. Fail here instead.
	@# Comment lines are excluded: the scripts document this trap by name.
	@bad=$$(grep -rnF '$${env.' $(SCRIPTS)/*.sh | grep -vE ':[0-9]+:[[:space:]]*#' || true); \
	if [ -n "$$bad" ]; then \
	  echo '  $${env.x} in a bash script - bash cannot expand a name containing a dot'; \
	  printf '%s\n' "$$bad" | sed 's/^/    /'; \
	  exit 1; \
	fi
	@# A settings default is not a place ${env.x} resolves either: the platform
	@# fills in node env values, not form defaults, and the import receives "".
	@# The env: block is where ${env.url} belongs.
	@if grep -nE '^[[:space:]]*default:.*env\.' jps/*.jps >/dev/null 2>&1; then \
	  echo '  a settings default references env.* - it does not resolve and arrives empty'; \
	  grep -nE '^[[:space:]]*default:.*env\.' jps/*.jps | sed 's/^/    /'; \
	  exit 1; \
	fi

.PHONY: check-docs
check-docs: ## Every `make <target>` mentioned in the docs must actually exist
	@targets=$$(grep -hoE '^[a-z][a-zA-Z0-9_-]*:' Makefile | tr -d ':' | sort -u); \
	refs=$$(grep -rhoE 'make [a-z][a-zA-Z0-9_-]*' README.md jps/*.jps ops/*.md 2>/dev/null \
	        | awk '{print $$2}' | sort -u); \
	bad=0; \
	for r in $$refs; do \
	  echo "$$targets" | grep -qx "$$r" || { echo "  phantom target: make $$r"; bad=1; }; \
	done; \
	[ $$bad -eq 0 ] && echo "  all $$(echo "$$refs" | wc -w) documented make targets exist" || exit 1

.PHONY: shellcheck
shellcheck: ## Lint the shell scripts
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 0; }
	@# -P scripts lets shellcheck follow the `. lib.sh` sources. Without it the
	@# directive looks unresolvable, so it reports SC1091 for every script and
	@# SC2034 for CIVICRM_APP_DIR, which lib.sh does use.
	shellcheck -x -P scripts -S warning $(SCRIPTS)/*.sh
	@echo "  shellcheck clean"

.PHONY: lint-unset
lint-unset: ## Fail on any variable reference that `set -u` would turn into a fatal error
	@python3 tests/unset-env-test.py

.PHONY: test
test: shellcheck lint-unset validate check-docs ## Everything that does not need Docker
	@bash tests/install-noninteractive-test.sh
	@bash tests/install-guard-test.sh
	@bash tests/set-base-url-test.sh
	@echo "  all static checks pass"

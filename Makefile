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

.PHONY: health
health: ## Full healthcheck: runtime, layout, DB, extension, cron
	$(SSHRUN) $(SCRIPTS)/90-healthcheck.sh

# Re-run provisioning on the EXISTING box, without deleting and re-importing.
# The fast iteration loop: fix a script, `make provision`, keep the volumes,
# the database and the uploaded extension archive.
.PHONY: provision
provision: ## Re-run all provisioning steps on the existing box (no re-import)
	$(SSHRUN) $(SCRIPTS)/00-preflight.sh
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
image-test: ## Boot the image locally and check it serves and denies private/
	@bash tests/image-test.sh

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
	             print('  OK')"

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
	shellcheck -x $(SCRIPTS)/*.sh

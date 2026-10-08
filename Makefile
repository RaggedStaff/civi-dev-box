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
.PHONY: preflight
preflight: ## Verify the PHP runtime against CiviCRM's requirements
	$(SSH) 'bash -s' < $(SCRIPTS)/00-preflight.sh

.PHONY: fetch
fetch: ## Re-materialise the release code and bind volumes
	$(SSH) 'bash -s' < $(SCRIPTS)/20-fetch-civicrm.sh

.PHONY: install
install: ## Run the non-interactive CiviCRM installer (idempotent)
	$(SSH) 'bash -s -- $(SITE_URL)' < $(SCRIPTS)/30-install-civicrm.sh

.PHONY: health
health: ## Full healthcheck: runtime, layout, DB, extension, cron
	$(SSH) 'bash -s' < $(SCRIPTS)/90-healthcheck.sh

.PHONY: up
up: preflight fetch install health ## preflight -> fetch -> install -> verify

.PHONY: push-scripts
push-scripts: ## Copy the deploy scripts onto the box
	scp $(SSH_OPTS) $(SCRIPTS)/45-deploy-archive.sh $(SSH):$(CIVICRM_DATA_DIR)/deploy-archive.sh
	scp $(SSH_OPTS) $(SCRIPTS)/lib.sh $(SSH):$(CIVICRM_DATA_DIR)/lib.sh

.PHONY: logs
logs: ## Tail the CiviCRM log
	$(SSH) 'find $(CIVICRM_DATA_DIR)/private/log -name "*.log" -exec tail -f {} +'

.PHONY: db
db: ## Open a MySQL client on the CiviCRM database
	$(SSH) 'mysql -u civicrm -p"$$CIVICRM_DB_PASS" civicrm'

.PHONY: sql
sql: ## Run a query: make sql Q="SELECT COUNT(*) FROM civicrm_contact"
	$(SSH) 'mysql -u civicrm -p"$$CIVICRM_DB_PASS" civicrm -e "$(Q)"'

.PHONY: shell
shell: ## Interactive SSH into the box
	$(SSH)

# =============================================================================
# MANIFEST DEPLOY
# =============================================================================
.PHONY: deploy
deploy: ## Deploy the JPS manifest
	@test -n "$(JPS_URL)" || { echo "Set JPS_URL to the public URL of jps/civi-standalone.jps"; exit 1; }
	@test -n "$(JELASTIC_API)" || { echo "Set JELASTIC_API (e.g. https://app.jpe.infomaniak.com/1.0)"; exit 1; }
	jps deploy -u "$(JPS_URL)" -e "$(JELASTIC_API)" $(JPS_OPTS)

.PHONY: validate
validate: ## Sanity-check the manifest locally
	@python3 -c "import yaml; d=yaml.safe_load(open('jps/civi-standalone.jps')); \
	             print('  type    :', d['type']); \
	             print('  nodes   :', [n['nodeType'] for n in d['nodes']]); \
	             print('  phpTag  :', d['settings']['fields'][4]['default']); \
	             print('  fields  :', len(d['settings']['fields'])); \
	             print('  events  :', [k for k in d if k.startswith('on')])"

.PHONY: shellcheck
shellcheck: ## Lint the shell scripts
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 0; }
	shellcheck -x $(SCRIPTS)/*.sh

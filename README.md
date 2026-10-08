# civi-dev-box

A reproducible [Jelastic](https://jelastic.com) / **Virtuozzo Application Platform**
environment for **CiviCRM Standalone**, built to host and test the
**dfc_civicrm** native extension.

| | |
| --- | --- |
| Panel | `app.jpe.infomaniak.com` (Jelastic PaaS, public provider) |
| Site | <https://dev.civi.sioldata.com> |
| Extension | [`dfc_civicrm`](https://github.com/zoro-jiro-san/dfc-civicrm) v0.1.0, pre-alpha |

The extension's own README records the blocker this box exists to clear:

> **no CiviCRM instance exists in this project's environment (BLK-005)**
> … nothing here has ever run inside a CiviCRM installation

and `tools/verify-install.sh` says:

> This is the half of CP-2 that cannot be done without a CiviCRM instance. It is
> written now, while the box does not exist, so that the first thing we do when a
> box arrives is run it rather than write it.

**So this project does not reimplement the extension's acceptance tests. It
provides the box, then runs the ones already written.**

---

## Pinned stack

| Component  | Version    | Rationale |
| ---------- | ---------- | --------- |
| App server | Apache + PHP | `apachephp-dockerized` — see below |
| PHP        | **8.4.26** | **Not 8.5 — see below** |
| Database   | **MariaDB 11.8.9** | CiviCRM documents *"11.4+ recommended"*; LTS |
| CiviCRM    | **6.18.2** | Current Standalone release |

### Why PHP 8.4 and not 8.5

**The only reason is the extension.** `dfc_civicrm`'s `info.xml` declares:

```xml
<php_compatibility>
  <ver>8.1</ver><ver>8.2</ver><ver>8.3</ver><ver>8.4</ver>
</php_compatibility>
```

8.5 is outside that declared range, and CiviCRM enforces the declared range when
registering an extension. So `cv ext:enable` would refuse `dfc_civicrm` on
PHP 8.5. **This is a hard blocker, not a preference.**

CiviCRM *core* is perfectly happy on 8.5 — its requirements page lists 8.3, 8.4
and 8.5 all as *"compatible and recommended"*, and 8.5 as the recommended
version for releases 6.16+. Nothing about the platform argues for 8.4; only the
extension does.

To move the box to 8.5.11, add `<ver>8.5</ver>` to the extension's `info.xml`
first, then change `phpTag`. Do not only change the tag — registration will
fail.

---

## Architecture

```
                    ┌────────────────────────────────────────────┐
   browser ────────▶│  cp   apachephp-dockerized  (PHP 8.4.26)   │
  dev.civi.sioldata │                                            │
         .com      │  $HOME/apps/civicrm/          ← ephemeral    │
                    │    civicrm.standalone.php                   │
                    │    core/                                    │
                    │    private ─┐                               │
                    │    public  ─┼─▶ /var/lib/civicrm-data/      │
                    │    ext     ─┘     (Jelastic volumes)        │
                    │  .user.ini → CiviCRM ini minimums          │
                    └──────────────────┬─────────────────────────┘
                                       │ links: sqldb:DB
                    ┌──────────────────▼─────────────────────────┐
                    │  sqldb  mariadb-dockerized  (11.8.9)       │
                    │  /etc/my.cnf.d/custom.cnf  ← tuned         │
                    └────────────────────────────────────────────┘
```

**Why Apache, not NGINX.** CiviCRM's Standalone release protects `private/` with
`.htaccess` — that is how it keeps `civicrm.settings.php`, which holds the DB
credentials, out of HTTP. Apache honours those rules; NGINX ignores them and
would need them reimplemented by hand. CiviCRM's docs present Apache and NGINX
as equals and recommend neither, so the release's own code decides it. See
[`ops/README-apache.md`](ops/README-apache.md).

**Why a JPS manifest and not a custom Docker image.** Official `php:8.4-*`
images are Debian trixie (13), which is *not* in Jelastic's custom-image
allowlist (`AlmaLinux 9`, `Alpine 3`, `CentOS 7/8`, `Debian 12`,
`Ubuntu 18.04–24.04` — **amd64 only**). A custom image would mean building PHP
yourself and permanently owning php.ini, opcache, extensions and vhost config.
The certified PHP container supplies all of that plus scaling, logs and the
config file manager.

**Why the writable trees are volumes.** `private/`, `public/` and `ext/` are
symlinked onto `/var/lib/civicrm-data`, so uploads, `civicrm.settings.php` and
the installed extension survive a redeploy. The release code is ephemeral and is
re-materialised by an `onAfterRestartNode [cp]` hook, so redeploys self-heal.

**No hardcoded paths.** The manifest never assumes where Jelastic puts the app.
`scripts/lib.sh` locates the project root by finding `civicrm.standalone.php`,
and resolves the database host from the injected link variables with fallbacks.
The same scripts therefore work whether run by the manifest or by hand over SSH.

---

## Deploying

### 1. Publish these scripts (see the FAQ at the bottom for why)

```bash
git remote -v      # push this repo to your org
# edit jps/civi-standalone.jps:
#   baseUrl: https://raw.githubusercontent.com/<org>/civi-dev-box/main/
```

### 2. Deploy the environment

```bash
export JELASTIC_API="https://app.jpe.infomaniak.com/1.0"
export JPS_URL="https://raw.githubusercontent.com/<org>/civi-dev-box/main/jps/civi-standalone.jps"

jps deploy -u "$JPS_URL" -e "$JELASTIC_API" \
  -s envName=civi-dev \
  -s siteUrl=https://dev.civi.sioldata.com \
  -s phpTag=8.4.26 \
  -s demoData=false
```

Or Dashboard → Import → JPS. The form exposes every setting.

### 3. Deploy the extension

The manifest deliberately does **not** deploy the extension, because
`dfc_civicrm` has **no git remote** and its `vendor/` + `composer.lock` are
gitignored — there is nothing on the box to clone, and a clone would be missing
the `siol-data/dfc-connector` runtime subset that export depends on.

Instead the extension ships as the archive its own `tools/build-release.sh`
produces:

```bash
make ext-build      # their tools/preflight + build-release.sh -> build/*.tar.gz
make ext-install    # scp the archive to the box, extract, cv ext:enable
make ext-verify     # their tools/verify-install.sh, on the box
```

`ext-build` delegates to the extension's own scripts. This project does not
reimplement their gates.

### 4. One manual step JPS cannot do

**Cron.** Scheduled mailings, the job queue and reminders all need it. Install
[`ops/crontab`](ops/crontab) via Dashboard → CUSTOMER → Cron Jobs.

Web-server config needs nothing: the box runs Apache, which honours the
`.htaccess` rules the CiviCRM release ships. Confirm it once with:

```bash
curl -sI https://dev.civi.sioldata.com/private/civicrm.settings.php   # 403 or 404
curl -sI https://dev.civi.sioldata.com/core/civicrm/version.php      # 403 or 404
```

### 5. Verify

```bash
make health         # runtime, layout, DB, extension, cron — one command
make ext-verify     # the extension's own install/uninstall acceptance test
```

---

## The extension loop

```bash
make ext-test       # 1098 unit tests, no box needed, ~25s
make ext-build      # build the archive
make ext-install    # ship it and run cv ext:enable + upgrade:sql
make ext-sql        # only pending migrations, after editing schema/*.entityType.php
make ext-disable    # cv ext:disable
make ext-enable     # cv ext:enable
```

Useful box targets:

```bash
make sql Q="SELECT COUNT(*) FROM civicrm_contact"
make logs
make db
make shell
```

---

## What the extension's own tests check

`verify-install.sh` runs the lifecycle that proves CP-2, and the box satisfies
its requirements: `cv ext:dir`, `cv ext:enable/disable/status`, `cv sql:query`,
plus `http://localhost` for the version probe. It asserts:

- the archive's `info.xml` key agrees with its directory name
- `info.xml` `<classloader>` declares `Civi\Dfc\` (the site does not run Composer,
  so the XML must carry the PSR-4 map — drift here fatals in production, not at install)
- the vendored connector is present
- the `CiviMix\Schema` upgrader created `civicrm_dfc_identity` and `civicrm_dfc_webid`
- `managed/*.mgd.php` created the DFC custom group
- all four permissions registered
- **`ext:disable` does not change the contact count** — the one irreversible
  failure mode
- re-enable is idempotent

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `cv ext:enable` refuses the extension | `php_compatibility` excludes the running PHP. dfc_civicrm declares 8.1–8.4; the box is 8.4.26. Raising `phpTag` to 8.5 causes exactly this. |
| `top-level directory does not match extension key` | The archive's root dir must be `dfc_civicrm/`, because CiviCRM resolves `<ext-dir>/<key>/<file>.php`. |
| `archive is missing part of the vendored DFC connector subset` | Built with `--no-vendor`. Rebuild with `tools/build-release.sh --force`. |
| `could not locate a CiviCRM Standalone project root` | `20-fetch-civicrm.sh` has not run, or set `CIVICRM_APP_DIR`. |
| `not currently supported in a URL subdirectory` | The domain must point at the project root, not a subdirectory. |
| `ONLY_FULL_GROUP_BY is ON` | MariaDB config did not apply — check `/etc/my.cnf.d/custom.cnf` and that `/etc/my.cnf` includes that directory. |
| `no civicrm cron entries` | Install `ops/crontab`. |
| `/private/civicrm.settings.php` is reachable over HTTP | `private/.htaccess` missing or `AllowOverride` too tight. Re-run `make fetch`; if it persists the platform is not allowing `.htaccess` overrides. |
| `.user.ini` seems ignored | Expected on mod_php — the `.htaccess` `php_value` block covers that case. Check which SAPI is running. |
| `the provided path is not a valid directory` from `cv` | ext-dir symlink not in place — `make fetch`. |

---

## Files

```
jps/civi-standalone.jps     the install image — import this
scripts/
  lib.sh                    shared helpers, path/DB discovery
  00-preflight.sh           fail fast on an unsatisfying runtime
  10-db-tune.sh             CiviCRM's documented DB requirements  [runs on sqldb]
  20-fetch-civicrm.sh       release code + bind volumes + .user.ini
  30-install-civicrm.sh     cv core:install, idempotent
  40-install-extension.sh   source-based deploy (git URL or local path)
  45-deploy-archive.sh      archive-based deploy  ← primary for dfc_civicrm
  90-healthcheck.sh         one command: is this box healthy?
ops/
  README-apache.md          why Apache, and what is auto-configured
  crontab                   CiviCRM scheduled jobs
ext-template/               a minimal valid extension, for testing the deploy path
```

---

## Known gaps

- **Script hosting.** The manifest fetches scripts from `${baseUrl}`, so the
  repo must be reachable over HTTP. Without a reachable `baseUrl` the
  environment still creates and you can run the scripts over SSH (`make up`),
  but nothing auto-provisions.
- **Tags are best-effort.** The Cloud Scripting reference (v8.15.1) still lists
  only PHP 7.4/8.0/8.1 as engines — stale. Confirm exact tag strings in
  Dashboard → New Environment, or on `hub.docker.com/r/jelastic/`, and override
  with `-s phpTag=...`.
- **`.htaccess` permissions.** If the platform's Apache sets a restrictive
  `AllowOverride`, `private/.htaccess` will not take effect. Verify with the two
  `curl` commands in step 4; that is why the check exists.
- **Cron cannot be created from JPS** on Jelastic.
- **`type="module"` in the extension's `info.xml`.** Its own comment says
  *"Since CiviCRM 6.26 every extension must be type=module"*, but 6.26 is a
  **future** release (CiviCRM versions are year-based; 6.26 ≈ 2027). On 6.18.2
  this attribute is either ignored or unexpected — worth confirming the
  extension still registers, since this has never been exercised against a real
  site. `make ext-verify` will surface it immediately.

---

## FAQ

**Why do the scripts need to be published to a URL?**
The JPS manifest can only run scripts with `cmd`, which executes shell commands
*inside* the container — but it has no way to transfer a file there. So the
manifest does `curl -fsS <url> | bash -s`. Jelastic's own app packages work the
same way (a manifest in a GitHub repo pulls its scripts from `raw.githubusercontent`).
If you'd rather not publish, skip it: the environment still deploys, and
`make up` pushes and runs the scripts over SSH instead.

**Why is PHP 8.4 when you earlier said 8.5 was fine?**
For CiviCRM core, 8.5 is fine and recommended. But this box's actual subject is
`dfc_civicrm`, whose `info.xml` declares `php_compatibility` up to 8.4 only.
CiviCRM enforces that declared range, so 8.5 would block the extension from
installing at all.

---

## Sources

- [CiviCRM installation requirements](https://docs.civicrm.org/installation/en/latest/requirements/) — PHP matrix, required extensions, DB requirements
- [Install CiviCRM Standalone](https://docs.civicrm.org/installation/en/latest/standalone/) — layout, permissions, `cv core:install`
- [CLI installer](https://docs.civicrm.org/installation/en/latest/general/cli-cv/) — `cv`
- [CiviCRM download](https://civicrm.org/download) — 6.18.2 standalone tarball
- [PHP versions](https://www.virtuozzo.com/application-management-docs/php-versions/) — engine availability
- [Software stack versions](https://www.virtuozzo.com/application-management-docs/software-stacks-versions/) — MariaDB tags, `jelastic/*` images
- [Container image requirements](https://www.virtuozzo.com/application-management-docs/container-image-requirements/) — base distro allowlist, amd64 only
- [Custom containers deployment](https://www.virtuozzo.com/application-management-docs/custom-containers-deployment/)
- [Cloud Scripting: basic configs](https://docs.cloudscripting.com/creating-manifest/basic-configs/) · [selecting containers](https://docs.cloudscripting.com/creating-manifest/selecting-containers/) · [custom scripts](https://docs.cloudscripting.com/creating-manifest/custom-scripts/)

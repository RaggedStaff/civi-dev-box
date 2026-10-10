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
| App image  | custom | `civicrm/civicrm-base:php8.5` — see below |
| PHP        | **8.5.11** | Matches CiviCRM 6.16+; the extension allows it |
| Database   | **`mariadb:12.3`** | Official image; creates the DB and user itself |
| CiviCRM    | **6.18.2** | Downloaded at install time, not baked into the image |

### Why custom images

Both nodes are Docker images rather than the provider's certified stacks. That
is not a preference — the certified ones could not be installed at all. Six
separate import failures were every one a property of those images rather than of
anything in this repo:

1. **`intl` shipped disabled.** CiviCRM requires it, so preflight refused.
2. **The provider's `php.ini` had a syntax error on line 688**, and PHP discards
   every directive after a parse error — *silently*: `php -m` still exits 0 and
   prints a normal module list. An appended `extension=intl.so` landed below the
   error and did nothing.
3. **`php --ini` printed its paths wrapped in double quotes.** Splitting on the
   colon captured `"/etc/php.ini"` including the quotes, so every write went to a
   file of that name in the working directory instead of the real config.
4. **The document root was `/var/www/html`**, not the path the scripts assumed.
5. **The Apache template shipped with HTTP Basic Auth** on the document root.
6. **The platform generates the database root password** and does not expose it
   where a provisioning script can rely on it.

`civicrm/civicrm-base:php8.5` is Debian 12 / amd64 — both inside the platform's
supported base-OS allowlist — and already provides PHP 8.5.11, `intl` compiled
in, `DocumentRoot /var/www/html`, `AllowOverride All` and no Basic Auth. The
`mariadb` image creates the database and user from `MARIADB_USER` /
`MARIADB_PASSWORD` / `MARIADB_DATABASE`, so there is no bootstrap script.

The Dockerfile verifies all of it **at build time**, so a missing requirement
fails the build rather than an import.

**Trade-off:** you lose the platform's certified-stack integration — its php.ini
management, its auto-tuned `my.cnf`, its dashboard PHP settings. That is the
point: you own that config now, in one readable file.

### Why PHP 8.5

CiviCRM's requirements page pairs the versions explicitly:

> PHP: PHP 8.3, 8.4 or 8.5 is recommended (**8.4 runs with CiviCRM 6.12–6.15,
> 8.5 with 6.16+**)

This box runs CiviCRM **6.18.2**, so 8.5 is the matched pair. 8.4 would be
running a release against a PHP version its own documentation does not pair it
with.

`dfc_civicrm` permits it too. Its `info.xml` declares:

```xml
<php_compatibility>
  <ver>8.1</ver><ver>8.2</ver><ver>8.3</ver><ver>8.4</ver><ver>8.5</ver>
</php_compatibility>
```

> **Note on history.** Earlier revisions of this repo pinned PHP 8.4 and cited
> this very element as the reason. That was true when written, and it stopped
> being true on **2026-10-08**: the reference `info.xml` on docs.civicrm.org
> listed only 8.1–8.4, which made 8.4 act as a ceiling, and the extension lifted
> it. Its own `tools/preflight.sh` records this. The rationale here has been
> corrected to match the current file rather than left standing.

---

## Architecture

```
                    ┌────────────────────────────────────────────┐
   browser ────────▶│  cp   apache                (PHP 8.5.11)   │
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

**Why a JPS manifest and not a custom Docker image.** Official `php:8.5-*`
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

### 1. Build and push the image

The manifest's app node points at a custom image, so **the image must be
pullable by the platform before you import**:

```bash
make image-build IMAGE=raggedstaff/civi-dev-box     # or any registry path
make image-push  IMAGE=raggedstaff/civi-dev-box
make image-test                                     # boots it, checks it serves
```

`make image-test` is the local acceptance check: it confirms HTTP 200 on `/` and
**403 on `/private/civicrm.settings.php`** — the credential leak, closed.

If you would rather not publish publicly, add a private registry in the dashboard
under *Custom templates* and point `appImage` at it.

### 2. Publish these scripts (see the FAQ at the bottom for why)

```bash
git remote -v      # push this repo to your org
# edit jps/civi-standalone.jps:
#   baseUrl: https://raw.githubusercontent.com/<org>/civi-dev-box/main/
```

### 3. Install the environment

There is **no `jps` CLI** — JPS is the *manifest format*, not a command. Two ways
to install it:

**Dashboard (recommended).** Log in to `https://app.jpe.infomaniak.com` →
**Import → Import manifest**, then paste:

```
https://raw.githubusercontent.com/RaggedStaff/civi-dev-box/main/jps/civi-standalone.jps
```

The form exposes every setting field, so `envName`, `siteUrl`, `phpTag`,
`dbPass` etc. are all editable before you commit to the install.

**REST API (scriptable).** The Dashboard's own import action calls:

```bash
export JELASTIC_API="https://app.jpe.infomaniak.com/1.0"
export JPS_URL="https://raw.githubusercontent.com/RaggedStaff/civi-dev-box/main/jps/civi-standalone.jps"
export JELASTIC_SESSION="..."   # see below

curl -sG "${JELASTIC_API}/environment/control/importmanifest" \
  --data-urlencode "session=${JELASTIC_SESSION}" \
  --data-urlencode "manifestUrl=${JPS_URL}" \
  --data-urlencode "envName=civi-dev" \
  --data-urlencode "siteUrl=https://dev.civi.sioldata.com" \
  --data-urlencode "phpTag=8.5.11" \
  --data-urlencode "demoData=false"
```

Every `settings.fields` entry in the manifest is a query parameter of the same
name; `baseUrl` can be overridden the same way. To get a session token, copy the
`session` value out of any Dashboard API request (dev tools → Network), or use
`POST ${JELASTIC_API}/users/authentication/rest-api` if your provider has REST
authentication enabled. `make deploy` wraps the curl above if you'd rather not
type it.

### 4. Iterating without re-importing

You do **not** have to delete and re-import to try a change. Once an environment
exists, push the script and run it in place:

```bash
make provision   # intl -> auth -> preflight -> fetch -> install -> health
```

That keeps the volumes, the database and any uploaded extension archive. Each
step is also a target on its own (`make fetch`, `make install`, `make health`,
`make fetch`, `make install`, `make health`), so you can re-run just the step you changed.

It needs SSH access to the app node — Dashboard → the node → **SSH**, which gives
you the `root@…` address to pass as `TARGET`:

```bash
make provision TARGET=root@node219317-civi-dev
```

`scripts/ssh-run.sh` does the transfer. It pushes the script **and** `lib.sh` to
the box, then executes the file. Note that the obvious alternative,
`ssh host 'bash -s' < script.sh`, does not work: a script read from stdin has no
`BASH_SOURCE`, so every script's `. lib.sh` line resolves to `/lib.sh`.

There is no database step to run: the official `mariadb` image creates the
database and user from `MARIADB_DATABASE` / `_USER` / `_PASSWORD` in the manifest.
To administer it by hand:

```bash
make db-root DB_TARGET=root@<db-node> DB_ROOT_PASS=<dbRootPass>
```

**Why re-import anyway.** The JPS hooks only run on install, and the
`onAfterRestartNode` hook re-runs just the release-code fetch. So `make
provision` does not cover everything a fresh import does — in particular
container-level changes that the platform itself applies at creation time. Reuse
the environment for iterating on scripts; re-import when the *topology* or the
node configuration changes.

### 5. Deploy the extension

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

### 6. One manual step JPS cannot do

**Cron.** Scheduled mailings, the job queue and reminders all need it. Install
[`ops/crontab`](ops/crontab) via Dashboard → CUSTOMER → Cron Jobs.

Web-server config needs nothing: the box runs Apache, which honours the
`.htaccess` rules the CiviCRM release ships. Confirm it once with:

```bash
curl -sI https://dev.civi.sioldata.com/private/civicrm.settings.php   # 403 or 404
curl -sI https://dev.civi.sioldata.com/core/civicrm/version.php      # 403 or 404
```

### 7. Verify

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
| `cv ext:enable` refuses the extension | `php_compatibility` excludes the running PHP. dfc_civicrm declares 8.1–8.5; the box is 8.5.11. Raising `phpTag` past 8.5 causes exactly this. |
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
Dockerfile                 the application image (FROM civicrm/civicrm-base:php8.5)
jps/civi-standalone.jps     the install image — import this
scripts/
  lib.sh                    shared helpers, path/DB discovery
  00-preflight.sh           fail fast on an unsatisfying runtime
  20-fetch-civicrm.sh       release code + bind volumes + .user.ini
  30-install-civicrm.sh     cv core:install, idempotent
  40-install-extension.sh   source-based deploy (git URL or local path)
  45-deploy-archive.sh      archive-based deploy  ← primary for dfc_civicrm
  90-healthcheck.sh         one command: is this box healthy?
  99-diagnose-web.sh        read-only: what is actually serving the site
  ssh-run.sh                push a script to the box and run it as a FILE
ops/
  README-apache.md          why Apache, and what is auto-configured
  crontab                   CiviCRM scheduled jobs
tests/
  image-test.sh             boots the image, asserts it serves and denies private/
  docroot-test.sh           document-root discovery against real httpd -S output
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
- **The CiviCRM download is not checksum-verified.** CiviCRM publishes no
  `.sha256`/`.md5` sidecar for the Standalone tarball — the sidecar URL redirects
  to a `NoSuchKey` — so there is nothing to fetch automatically and the default
  path rests on TLS alone. Set `CIVICRM_SHA256` to an out-of-band value to make
  it a verified download; the script says so out loud when it is unset.
- **Cron cannot be created from JPS** on Jelastic. `cron` is installed and
  running in the image, so the only remaining step is the crontab entry itself
  (Dashboard → CUSTOMER → Cron Jobs, using `ops/crontab`).
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
manifest curls each script into `$HOME/.civi-scripts` and then runs it as a
file. (It must be a *file*: piping into `bash -s` leaves `BASH_SOURCE` unset,
which breaks every `source lib.sh` line. Jelastic's own app packages use the
pipe form and hit this too.)
If you'd rather not publish, skip it: the environment still deploys, and
`make up` pushes and runs the scripts over SSH instead.

**Why did this used to pin PHP 8.4?**
Because `dfc_civicrm`'s `php_compatibility` stopped at 8.4, and CiviCRM enforces
that declared range when registering an extension. The extension lifted the
ceiling on 2026-10-08, so the box now uses 8.5 — which is also what CiviCRM's
own documentation pairs with 6.16+. See the note under *Pinned stack*.

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

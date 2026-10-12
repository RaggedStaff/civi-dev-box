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

> **To install it, read [Installing on Jelastic](#installing-on-jelastic).** In
> short: build and push the application image first, point the manifest at it,
> then import. The image has to exist before the platform can create anything.

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

## Installing on Jelastic

Six steps, in order. **Step 1 must happen before step 4** — the platform cannot
create the environment until the application image exists in a registry it can
pull from.

Estimated time: ~4 minutes to build and push the image, ~3 minutes for the
platform to create the environment.

---

### 1. Push the application image

The manifest's app node is a **custom Docker image**, not one of the provider's
certified stacks. Jelastic has to pull it, so it has to exist in Docker Hub (or
another registry the platform can reach) first.

```bash
cd <this repo>

docker login                                    # once, if you have not already
make image-build IMAGE=<your-dockerhub-user>/civi-dev-box
make image-push  IMAGE=<your-dockerhub-user>/civi-dev-box
```

That builds `civicrm/civicrm-base:php8.5` plus the additions this box needs
(`cron`, `git`, `unzip`, `composer`, and the `private/` deny rules), and pushes it
as `<your-dockerhub-user>/civi-dev-box:8.5.11`.

Check it works before going further:

```bash
make image-test
```

Expected:

```
/                              HTTP 200
/private/civicrm.settings.php  HTTP 403   CORRECT (denied)
```

That 403 is the important one — it proves the directory holding your database
credentials is not web-readable.

> **Prefer not to publish publicly?** Add a private registry in the dashboard
> under *Custom templates*, then use that path for `IMAGE` and for the manifest's
> `appImage` field.

### 2. Check the manifest points at your image

Open `jps/civi-standalone.jps` and set `appImage` to the tag you just pushed:

```yaml
- caption: Application image
  name: appImage
  default: "raggedstaff/civi-dev-box:8.5.11"    # <-- yours
```

Then commit and push, because **step 4 fetches the manifest over HTTP** — the
platform downloads the file from GitHub, it does not use your local copy:

```bash
git add jps/civi-standalone.jps
git commit -m "point the manifest at our image"
git push
```

### 3. (Optional) Check the database image

The database node is the official `mariadb` image:

```yaml
- caption: Database image
  name: dbImage
  default: "mariadb:12.3"
```

You do not need to change this. It creates the database and user itself from the
`MARIADB_*` variables in the manifest, which is why there is no database
provisioning step to run.

### 4. Import the manifest

Log in to <https://app.jpe.infomaniak.com>, then **Import → Import manifest**, and
paste:

```
https://raw.githubusercontent.com/RaggedStaff/civi-dev-box/main/jps/civi-standalone.jps
```

The form pre-fills every setting. Check these three and leave the rest alone:

| Field | Should be | Why it matters |
| --- | --- | --- |
| `appImage` | your image from step 1 | **wrong here and the install fails immediately** |
| `siteUrl` | `https://dev.civi.sioldata.com` | baked into the install; changing it later means re-installing |
| `extSource` | *blank* | only for a git-hosted copy of the extension; this box deploys it separately in step 6 |

Then click **Install**. Progress shows under the environment as it goes; the
`onInstall` hooks fetch the scripts and run them, so do not expect to click
anything again.

### 5. Add cron (one manual step)

JPS cannot create a cron job, and without one, scheduled mailings, the job queue
and reminders are all inert. `cron` itself is already installed and running in
the image — this is just the crontab entry.

**Dashboard → CUSTOMER → Cron Jobs**, using the file at
[`ops/crontab`](ops/crontab).

### 6. Deploy the extension

The manifest deliberately does **not** deploy the extension. `dfc_civicrm` has no
git remote and its `vendor/` is gitignored, so there is nothing on the box to
clone. It ships as the archive its own `tools/build-release.sh` produces.

From your workstation:

```bash
make ext-build      # runs the extension's own preflight + build-release.sh
make ext-install    # uploads the archive and runs cv ext:enable
make ext-verify     # runs the extension's own verify-install.sh, on the box
```

Each needs `TARGET` set to the app node's SSH address (Dashboard → the node →
**SSH**):

```bash
make ext-install TARGET=root@node12345-civi-dev
```

### 7. Verify

```bash
make health TARGET=root@node12345-civi-dev
```

and in a browser: <https://dev.civi.sioldata.com/civicrm/login>.

---

## Installing without the Dashboard

There is **no `jps` CLI** — JPS is the manifest *format*, not a command. The
Dashboard's own import action calls this REST endpoint:

```bash
export JELASTIC_API="https://app.jpe.infomaniak.com/1.0"
export JPS_URL="https://raw.githubusercontent.com/RaggedStaff/civi-dev-box/main/jps/civi-standalone.jps"
export JELASTIC_SESSION="..."     # see below

curl -sG "${JELASTIC_API}/environment/control/importmanifest" \
  --data-urlencode "session=${JELASTIC_SESSION}" \
  --data-urlencode "manifestUrl=${JPS_URL}" \
  --data-urlencode "envName=civi-dev" \
  --data-urlencode "siteUrl=https://dev.civi.sioldata.com" \
  --data-urlencode "appImage=<your-dockerhub-user>/civi-dev-box:8.5.11" \
  --data-urlencode "dbImage=mariadb:12.3" \
  --data-urlencode "demoData=false"
```

Every entry in the manifest's `settings.fields` is a query parameter of the same
name; `baseUrl` can be overridden the same way. To get a session token, copy the
`session` value out of any Dashboard API request (browser dev tools → Network),
or use `POST ${JELASTIC_API}/users/authentication/rest-api` if your provider has
REST authentication enabled. `make deploy` wraps this call.

## Iterating without re-importing

You do **not** have to delete and re-import to try a change. Once an environment
exists, push the script and run it in place:

```bash
make provision   # preflight -> fetch -> install -> health
```

That keeps the volumes, the database and any uploaded extension archive. Each
step is also a target on its own (`make fetch`, `make install`, `make health`),
so you can re-run just the step you changed.

It needs SSH access to the app node — Dashboard → the node → **SSH**, which gives
you the `root@…` address to pass as `TARGET`:

```bash
make provision TARGET=root@node12345-civi-dev
```

`scripts/ssh-run.sh` does the transfer. It pushes the script **and** `lib.sh` to
the box, then executes the file. Note that the obvious alternative,
`ssh host 'bash -s' < script.sh`, does not work: a script read from stdin has no
`BASH_SOURCE`, so every script's `. lib.sh` line resolves to `/lib.sh`. That exact
bug stopped every import before the manifest was changed to download scripts to
disk.

There is no database step to run: the official `mariadb` image creates the
database and user from `MARIADB_DATABASE` / `_USER` / `_PASSWORD` in the manifest.
To administer it by hand:

```bash
make db-root DB_TARGET=root@<db-node> DB_ROOT_PASS=<dbRootPass>
```

**When you still need a re-import.** The JPS hooks only run on install, and
`onAfterRestartNode` re-runs just the release-code fetch. So `make provision`
does not cover everything a fresh import does — in particular image changes and
node configuration. Reuse the environment for iterating on scripts; re-import
when the image tag, topology or node settings change.

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
| `cv ext:enable` refuses the extension | `php_compatibility` excludes the running PHP. dfc_civicrm declares 8.1–8.5; the image is PHP 8.5.11. Rebuilding on a newer PHP than that needs `<ver>` added to the extension's `info.xml` first. |
| `top-level directory does not match extension key` | The archive's root dir must be `dfc_civicrm/`, because CiviCRM resolves `<ext-dir>/<key>/<file>.php`. |
| `archive is missing part of the vendored DFC connector subset` | Built with `--no-vendor`. Rebuild with `tools/build-release.sh --force`. |
| `could not locate a CiviCRM Standalone project root` | `20-fetch-civicrm.sh` has not run, or set `CIVICRM_APP_DIR`. |
| `not currently supported in a URL subdirectory` | The domain must point at the project root, not a subdirectory. |
| `ONLY_FULL_GROUP_BY is ON` | The stock MariaDB image default. Not yet tuned — see *Known gaps*. |
| `no civicrm cron entries` | Install `ops/crontab` (Dashboard → CUSTOMER → Cron Jobs). |
| `/private/civicrm.settings.php` is reachable over HTTP | The image ships the deny rule, so this means the box is **not** running your image. Check `appImage` in the manifest matches what you pushed, and re-import. |
| Import fails immediately with no script output | Almost always `appImage`: the platform could not pull the image. Check the tag exists and is public. |
| `the database ... refused these credentials` | Wrong `dbPass`, or the `/var/lib/mysql` volume already holds a database — in which case the `MARIADB_*` variables were ignored and the old credentials are still in force. Delete the environment or the volume and re-import. |
| `the database ... did not become reachable` | A connection problem, not a credentials one: nothing is listening, or the container is still initialising. Check the database node's status and logs. |
| `...: unbound variable` | A script referenced an environment variable the manifest does not set, and `set -u` killed it. `make lint-unset` finds this class of bug before import. |
| Site returns **502** | The platform's frontend is up but nothing is serving behind it. Run `make why-502 TARGET=root@<node>` — it reports whether a web server is alive, what it is listening on, and whether the document root answers. A 502 on a *custom* domain looks identical whether the domain is wrong, SSL is unprovisioned, or the app was never running, so check this first. |
| Browser warns about the certificate on a custom domain | Jelastic is serving its own wildcard (`*.jcloud-ver-jpe.ik-server.com`), which does not cover your domain. Enable Let's Encrypt for the domain in the dashboard — the CNAME alone does not provision a certificate. |
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
  db-wait-test.sh           wait_for_db against a real MariaDB, all four outcomes
  unset-env-test.py         fails on any reference `set -u` would turn fatal
  docroot-test.sh           document-root discovery against real httpd -S output
ext-template/               a minimal valid extension, for testing the deploy path
```

---

## Known gaps

- **Script hosting.** The manifest fetches scripts from `${baseUrl}`, so the
  repo must be reachable over HTTP. Without a reachable `baseUrl` the
  environment still creates and you can run the scripts over SSH (`make provision`),
  but nothing auto-provisions.
- **The image must be pushed before you can import.** The app node is a custom
  Docker image, so the platform cannot create the environment until that image
  exists in a registry it can pull from. This is why it is step 1.
- **`sql_mode` is not tuned yet.** MariaDB 12.3 defaults to `ONLY_FULL_GROUP_BY`,
  which CiviCRM's requirements page says to turn off. The fix is a `.cnf` in
  `/etc/mysql/conf.d/`, so it needs either a small DB image or a documented
  manual step. Not done in this change, and flagged because it is the most likely
  cause of odd behaviour once the box is up.
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
`make provision` pushes and runs the scripts over SSH instead.

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

# PHP extensions

## Why there is a script for this

CiviCRM's requirements are explicit:

> PHP INTL - required for outputting localized formatted number strings from
> CiviCRM 5.28 onwards

So `intl` is not optional polish. `00-preflight.sh` refuses to continue without
it, which is correct behaviour but means a bare import cannot succeed on an image
that ships PHP without `intl` loaded.

`05-enable-php-ext.sh` runs before preflight and fixes it when it can.

## What the platform actually ships

Virtuozzo's **PHP Extensions** documentation lists a per-server folder of dynamic
extensions that can be enabled from php.ini, and `intl.so` is in that list for
all three of Apache PHP, NGINX PHP and LiteSpeed PHP. The documented procedure is:

1. Node → **Config**
2. `etc` → `php.ini`
3. Find the section for the extension, uncomment `extension=intl.so`
4. Save, restart the node

So the binary is usually already on disk. Only the `extension=` line is missing.

## What the script does

It discovers paths at runtime instead of assuming them, because the module
directory differs between layouts (`/usr/lib64/php/modules`,
`/usr/local/lib/php/modules`, `/usr/local/etc/php/conf.d`, ...) and guessing
wrong yields an ini edit that silently does nothing.

| Situation | What happens |
| --- | --- |
| `intl` already loaded | Nothing. |
| `intl.so` in PHP's own `extension_dir` | Enabled via a conf.d drop-in, or appended to php.ini if there is no scan dir. **Expected path.** |
| `.so` present but PHP won't load it | The ini change is reverted and the run stops. |
| No `.so`, but `docker-php-ext-install` exists | Compiled with `libicu-dev`. **Ephemeral** — see below. |
| No `.so`, no build tooling | Stops, and points at the dashboard route above. |

Set `CIVICRM_EXT_TO_ENABLE=<name>` to use it for a different extension.

## Gotcha: `php --ini` quotes its paths

On this platform, `php --ini` reports:

```
Loaded Configuration File: "/etc/php.ini"
Scan for additional .ini files in: "/etc/php.d"
```

**with the double quotes included.** Anything that parses that output by
splitting on the colon keeps the quote characters, so the "path" becomes
`"/etc/php.ini"` and:

- `>> '"/etc/php.ini"'` creates a file literally named `"/etc/php.ini"` in the
  current working directory
- `mkdir -p "$(dirname '"/etc/php.d"/civi-intl.ini')"` creates a directory
  literally named `"` and hangs the rest of the path off it

Both *succeed*, so nothing looks wrong until you notice PHP was never actually
told to load anything. The symptom is a failure that reads exactly like "this
PHP build cannot load `intl.so`", which sends you looking for an API-version
mismatch that isn't there.

Two defences, both in `05-enable-php-ext.sh`:

- strip the surrounding quotes when parsing
- refuse to write unless the target is an **absolute** path whose parent
  directory exists, so a malformed path can never masquerade as a successful
  write

`extension_dir` comes from `php -r 'echo ini_get("extension_dir");'` rather than
`php --ini`, which is why it was never affected.

## The ephemeral case

A compiled extension lives in the container filesystem, not on the volume, so a
node replacement loses it. Two things mitigate that:

- `onAfterRestartNode [cp]` re-runs the script before anything else, so a
  restart re-enables it.
- The script prints a warning when it takes this path, so it is visible rather
  than silent.

If you keep replacing the node, a custom image is the durable answer. The
platform supports custom containers from any registry, but the base OS must be
one of the supported distributions (Debian 12, Ubuntu 18.04–24.04, AlmaLinux 9,
Alpine 3, CentOS 7–8) and the architecture must be amd64. Official
`php:8.5-apache` images are on Debian 13, which is **not** in that list — so
they need a rebase or a different source image, not just a `FROM` line.

## Verify

```bash
php -m | grep -x intl          # must print "intl"
php --ini                      # confirm where the directive was written
make health                    # full box check
```
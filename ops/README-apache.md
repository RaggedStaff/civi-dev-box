# Apache notes

The box runs **Apache + PHP** (`nodeType: apache` in the JPS manifest) rather
than NGINX. This is deliberate — no NGINX vhost file is shipped or needed.

## Why Apache

CiviCRM's Standalone release protects its `private/` tree with `.htaccess`
files. That is the mechanism CiviCRM itself relies on to keep
`civicrm.settings.php` — which contains your database credentials — unreadable
over HTTP. Apache honours `.htaccess`; NGINX ignores it, so on NGINX those rules
have to be reimplemented by hand in a vhost.

For this project Apache is also the lower-risk choice:

- `dfc_civicrm` registers its `/civicrm/dfc/v2` routes through
  `xml/Menu/dfc_civicrm.xml`, so it needs no URL rewriting of its own — but
  CiviCRM **core** still does, and Apache gives you that for free.
- The Jelastic Apache template is one of the most widely deployed of their PHP
  stacks, so support surface is broader.

## Is it the "recommended" stack?

Honestly: **no, neither is.** CiviCRM's installation guide presents Apache and
NGINX vhost examples as equals and names no preferred server. The requirements
page does not mention a web server at all. So the choice comes down to what the
release code expects, and the release ships `.htaccess`.

## What this box configures automatically

`scripts/20-fetch-civicrm.sh` writes:

| File | Purpose |
| --- | --- |
| `.user.ini` | CiviCRM ini minimums. Honoured by PHP-FPM/CGI. Inert on mod_php. |
| `.htaccess` | `php_value` equivalents of the same settings for mod_php. |
| `private/.htaccess` | `Require all denied` — blocks the DB-credential file. |
| `core/.htaccess` | `Require all denied` — core PHP is not an entrypoint. |

Both ini paths are written because the correct one depends on the SAPI and the
wrong one is **silently ignored** — `.user.ini` is read by nobody under
mod_php, and `php_value` is not permitted under PHP-FPM. Neither touches the
platform's global `php.ini`, so both survive a redeploy.

Only `PHP_INI_PERDIR`-capable directives are set via `php_value`. Setting
`opcache.revalidate_freq` there would make Apache return 500 on every request,
so the opcache settings live in `.user.ini` only.

## Verify it

```bash
curl -sI https://dev.civi.sioldata.com/private/civicrm.settings.php   # 403 or 404
curl -sI https://dev.civi.sioldata.com/core/civicrm/version.php      # 403 or 404
curl -sI https://dev.civi.sioldata.com/civicrm                       # 200 or 302
```

`make health` checks the layout; the two `curl` calls above are the ones that
matter for this file's existence.

## If you ever move to NGINX

NGINX ignores `.htaccess`, so the three files above would need reimplementing in
a vhost: `deny all` for `/private/`, `/core/` and dotfiles, plus an FPM
`fastcgi_pass` block. On Jelastic the vhost path is platform-specific, which
makes that a manual step — one of the reasons this box is Apache.

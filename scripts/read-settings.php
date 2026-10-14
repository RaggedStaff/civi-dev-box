<?php
/**
 * read-settings.php - report what a CiviCRM settings file actually defines.
 *
 *   php read-settings.php /var/www/html/private/civicrm.settings.php
 *
 * Two strategies, in order of trustworthiness:
 *
 *   1. LOAD the file in a SUBPROCESS and inspect what it defined. This is
 *      ground truth - no assumptions about the file's shape, and it is exactly
 *      what CiviCRM does. If loading produces a populated $civicrm_setting, the
 *      file is fine and any earlier "could not read it" was this parser's fault.
 *
 *      The subprocess matters. The file is PHP that this script does not
 *      control: it may call die(), it may print to stdout, it may need
 *      CiviCRM's bootstrap. Running it inline, a single die() takes the
 *      diagnostic down with it and prints nothing - which is indistinguishable
 *      from "the file is empty". So the child writes its answer to a temp file
 *      and the parent treats anything it cannot parse as "no answer".
 *
 *   2. If the file yields nothing loadable, fall back to a token_get_all() scan
 *      for $civicrm_setting['k'] = v.
 *
 * Strategy 1 exists because this parser was wrong three times and each failure
 * looked exactly like a genuinely empty file.
 */
$f = $argv[1] ?? '';
if (!is_file($f)) {
    fwrite(STDERR, "no such file: $f\n");
    exit(1);
}

$report = [
    'strategy' => null,
    'settings' => [],
    'notes'    => [],
];

// --- Strategy 1: load it out-of-process and see what came out ----------------
$tmp = tempnam(sys_get_temp_dir(), 'civisettings');
$child = 'require $argv[1];'
    . ' $found = null;'
    . ' foreach (["civicrm_setting","civicrm_config","_civicrm_setting","settings"] as $n) {'
    . '   if (isset($$n) && is_array($$n) && $$n) { $found = $$n; break; }'
    . ' }'
    . ' file_put_contents($argv[2], json_encode($found));';

$cmd = escapeshellarg(PHP_BINARY)
    . ' -d display_errors=0'
    . ' -d error_reporting=0'
    . ' -r ' . escapeshellarg($child)
    . ' ' . escapeshellarg($f)
    . ' ' . escapeshellarg($tmp);

$stdout = [];
$rc = 0;
exec($cmd . ' 2>/dev/null', $stdout, $rc);

$loaded = null;
if (is_file($tmp)) {
    $raw = file_get_contents($tmp);
    if (is_string($raw) && $raw !== '' && $raw !== 'null') {
        $decoded = json_decode($raw, true);
        if (is_array($decoded) && $decoded !== []) {
            $loaded = $decoded;
        }
    }
}
@unlink($tmp);

if ($loaded !== null) {
    $report['strategy'] = 'load';
    $report['notes'][] = sprintf(
        'loaded the file in a subprocess (exit %d) and read back %d keys',
        $rc,
        count($loaded)
    );
    foreach ($loaded as $k => $v) {
        if (is_scalar($v)) {
            $report['settings'][(string) $k] = (string) $v;
        } elseif (is_array($v)) {
            $report['settings'][(string) $k] = '(array of ' . count($v) . ')';
        } else {
            $report['settings'][(string) $k] = '(' . gettype($v) . ')';
        }
    }
} else {
    $report['strategy'] = 'token';
    $report['notes'][] = $rc === 0
        ? 'the file loaded but defined none of: civicrm_setting, civicrm_config, settings'
        : "loading it out-of-process exited {$rc} (it may need CiviCRM's bootstrap, or call die())";
    $report['settings'] = token_scan((string) file_get_contents($f));
}

// The keys we most care about, surfaced first so a glance answers the question.
$report['summary'] = [];
foreach (['civicrm.base_url', 'base_url', 'dsn', 'db_hostname', 'db_port',
          'database', 'db_username', 'db_password', 'siteKey'] as $k) {
    $report['summary'][$k] = $report['settings'][$k] ?? '(not set)';
}

echo json_encode($report, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";

/**
 * Fallback: tokenise and read $civicrm_setting['k'] = v.
 */
function token_scan(string $s): array
{
    $tokens = token_get_all($s);
    $n = count($tokens);
    $out = [];

    $isWs = function ($t) {
        return (is_array($t) && $t[0] === T_WHITESPACE) || $t === ' ';
    };

    for ($i = 0; $i < $n; $i++) {
        if (!is_array($tokens[$i]) || $tokens[$i][0] !== T_VARIABLE
            || $tokens[$i][1] !== '$civicrm_setting') {
            continue;
        }
        $i++;

        $shape = ['[', T_CONSTANT_ENCAPSED_STRING, ']', '='];
        $key = null;
        $ok = true;
        for ($j = 0; $j < count($shape); $j++) {
            while ($i < $n && $isWs($tokens[$i])) {
                $i++;
            }
            if ($i >= $n) {
                $ok = false;
                break;
            }
            $t = $tokens[$i];
            if (is_int($shape[$j])) {
                if (!is_array($t) || $t[0] !== $shape[$j]) {
                    $ok = false;
                    break;
                }
                if ($j === 1) {
                    $key = unquote($t[1]);
                }
            } elseif ($t !== $shape[$j]) {
                $ok = false;
                break;
            }
            $i++;
        }
        if (!$ok || $key === null) {
            continue;
        }

        while ($i < $n && $isWs($tokens[$i])) {
            $i++;
        }
        $v = $tokens[$i] ?? null;
        if (is_array($v) && $v[0] === T_CONSTANT_ENCAPSED_STRING) {
            $out[$key] = unquote($v[1]);
        } elseif (is_array($v) && $v[0] === T_LNUMBER) {
            $out[$key] = $v[1];
        } elseif ($v === '[' || $v === '(') {
            $out[$key] = '(not a scalar)';
        }
    }
    return $out;
}

/** Turn a PHP string literal token into its value. */
function unquote(string $literal)
{
    if (strlen($literal) < 2) {
        return $literal;
    }
    $quote = $literal[0];
    $body = substr($literal, 1, -1);
    if ($quote === "'") {
        return preg_replace('/\\\\([\\\\\'])/', '$1', $body);
    }
    return stripcslashes($body);
}
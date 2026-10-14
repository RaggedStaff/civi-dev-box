<?php
/**
 * read-settings.php - print the values CiviCRM actually cares about, as JSON.
 *
 *   php read-settings.php /var/www/html/private/civicrm.settings.php
 *
 * Parses $civicrm_setting['key'] = value; with token_get_all() rather than a
 * regex, because the values are arbitrary strings: a database password like
 * civiDb!2026 contains characters that are regex metacharacters. An earlier
 * diagnostic used a regex and reported "(not set)" for every key on a
 * perfectly valid file.
 *
 * A separate file rather than an inline `php -r` because the backslashes and
 * quotes these token tests need do not survive two layers of shell quoting.
 *
 * Whitespace arrives as a T_WHITESPACE *token*, not as a ' ' string - a version
 * that compared against the string silently skipped nothing and matched
 * nothing, returning an empty result while appearing to work.
 */
$f = $argv[1] ?? '';
$s = @file_get_contents($f);
if ($s === false) {
    fwrite(STDERR, "cannot read $f\n");
    exit(1);
}

$tokens = token_get_all($s);
$n = count($tokens);
$out = [];

$isWs = function ($t) {
    return (is_array($t) && $t[0] === T_WHITESPACE) || $t === ' ';
};

/**
 * Turn a PHP string literal token into its value.
 *
 * Stripping the quotes with trim("'\"") is not enough: the token still holds
 * PHP's source escapes, so a password of it's-complicated came back as
 * it\'s-complicated - wrong in a way that looks like a permissions problem.
 *
 * Single-quoted PHP strings only interpret \\ and \'; every other backslash is
 * literal. Double-quoted ones additionally interpret \n, \t, \xNN and so on, so
 * stripcslashes() is close enough for the values we read.
 */
function unquote(string $literal) {
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

for ($i = 0; $i < $n; $i++) {
    if (!is_array($tokens[$i]) || $tokens[$i][0] !== T_VARIABLE
        || $tokens[$i][1] !== '$civicrm_setting') {
        continue;
    }
    $i++;   // step past the variable itself; the shape walk starts at '['

    // Walk the expected shape: [ 'key' ] = <value>
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
        // Token-type constants are INTEGERS, not arrays. Branching on
        // is_array($shape[$j]) was always false, so every comparison degenerated
        // into `$tokenArray === 269` and every assignment was skipped.
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
        $i++;   // consume the token just matched
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
    } elseif ($v === '-') {
        $i++;
        if (is_array($tokens[$i] ?? null) && $tokens[$i][0] === T_LNUMBER) {
            $out[$key] = '-' . $tokens[$i][1];
        }
    } elseif ($v === '[' || $v === '(') {
        $out[$key] = '(not a scalar)';
    } elseif ($v === 't' || $v === 'f' || $v === 'T' || $v === 'F') {
        // true / false, tokenised as separate literals in some PHP versions
        $out[$key] = '';
    }
}

echo json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
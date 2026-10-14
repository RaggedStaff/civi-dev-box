<?php
/**
 * read-attr.php - print one root-element attribute of an XML file.
 *
 *   php read-attr.php info.xml key
 *   php read-attr.php info.xml version   # <version> element, for convenience
 *
 * CiviCRM reads `key`, `type` and `file` off the <extension> ROOT element as
 * attributes, not as child elements. A grep for "<key>" therefore matches
 * nothing and, if used as a check, silently passes - which is exactly how an
 * extension ends up deployed under the wrong name and never registering.
 *
 * Prints nothing (exit 0) when the attribute is absent, so callers can treat
 * absence as "unknown" rather than as an error.
 */
$file = $argv[1] ?? '';
$want = $argv[2] ?? 'key';

if (!is_file($file)) {
    fwrite(STDERR, "no such file: $file\n");
    exit(1);
}

libxml_use_internal_errors(true);
$xml = simplexml_load_file($file);
if ($xml === false) {
    fwrite(STDERR, "cannot parse $file\n");
    exit(1);
}

$attrs = $xml->attributes();
if ($attrs !== null && isset($attrs[$want])) {
    echo trim((string) $attrs[$want]), "\n";
    exit(0);
}

// Fall back to a child element, for things like <version>0.1.0</version>.
$c = $xml->{$want};
if ($c !== null && trim((string) $c) !== '') {
    echo trim((string) $c), "\n";
}

exit(0);
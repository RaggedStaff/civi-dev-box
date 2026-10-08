<?php

/**
 * Entry point class for the Template extension.
 *
 * CiviCRM instantiates this from the <extension> declaration in info.xml.
 */

class CRM_Template_Extension_Template
{
    /**
     * Fires after the extension is enabled/disabled on a site.
     *
     * @param bool $isEnabled
     */
    public static function onToggle($isEnabled): void
    {
        // Nothing to do - this exists so you have a hook to hang code on and
        // can confirm the extension was actually loaded by the dev box.
    }
}

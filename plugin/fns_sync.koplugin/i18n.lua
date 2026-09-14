--[[--
M11 i18n: English UI translations for English-language users.

KOReader's gettext singleton loads only its own l10n/<lang>/koreader.mo;
third-party plugin msgids (ours are Chinese) are never in there. Worse,
changeLang() short-circuits en_US to "untranslated" (translation table
stays empty), so English users would see raw Chinese msgids.

Fix: at plugin init, if the KOReader UI language is English, merge
locale/en_US.lua into the shared gettext.translation table. Key spaces
don't overlap with KOReader's own English msgids, so core translations
are unaffected.

Pure logic lives here (unit-testable without KOReader); the gettext
integration point is a single call in main.lua init.
--]]

local I18n = {}

--- Whether this UI language should get English plugin translations.
-- @string lang G_reader_settings "language" value ("en_US", "en_GB",
-- "zh_CN", "C", nil, ...)
function I18n.needsEnglish(lang)
    return type(lang) == "string" and lang:sub(1, 2) == "en"
end

--- Merge a translation table into gettext's shared translation table.
-- Idempotent: re-merging the same locale writes identical values.
function I18n.merge(target, translations)
    for k, v in pairs(translations) do
        target[k] = v
    end
end

return I18n

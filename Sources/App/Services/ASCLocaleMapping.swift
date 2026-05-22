import Foundation

// ASC localizations are keyed by locale (e.g. "en-US", "ja"), but the rest of
// keywordista keys everything by iTunes storefront country code ("us", "jp").
// This table is the bridge: given the locale ASC returns, which storefront(s)
// should that keyword list appear under?
//
// A handful of locales legitimately fan out to multiple storefronts
// (e.g. `en-GB` is also used in Ireland's storefront), so the value side is a
// `[String]`. Anything not in the table is dropped — the user sees no false
// positives, just a silent miss for an unusual storefront they probably
// aren't tracking anyway.
enum ASCLocaleMapping {
    static let table: [String: [String]] = [
        // English
        "en-US": ["us"],
        "en-GB": ["gb", "ie"],
        "en-AU": ["au", "nz"],
        "en-CA": ["ca"],
        "en-SG": ["sg"],
        "en-IN": ["in"],

        // German
        "de-DE": ["de", "at", "ch"],

        // French
        "fr-FR": ["fr", "be", "ch", "lu", "mc"],
        "fr-CA": ["ca"],

        // Spanish
        "es-ES": ["es"],
        "es-MX": ["mx"],
        "es-419": ["mx", "ar", "cl", "co", "pe", "ec", "uy", "ve", "bo", "py", "do", "gt", "hn", "sv", "ni", "cr", "pa"],

        // Italian
        "it": ["it"],
        "it-IT": ["it"],

        // East Asian
        "ja": ["jp"],
        "ja-JP": ["jp"],
        "ko": ["kr"],
        "ko-KR": ["kr"],
        "zh-Hans": ["cn"],
        "zh-Hans-CN": ["cn"],
        "zh-Hant": ["tw", "hk"],
        "zh-Hant-TW": ["tw"],
        "zh-Hant-HK": ["hk"],

        // Portuguese
        "pt-BR": ["br"],
        "pt-PT": ["pt"],

        // Slavic / Eastern Europe
        "ru": ["ru"],
        "ru-RU": ["ru"],
        "pl": ["pl"],
        "pl-PL": ["pl"],
        "uk": ["ua"],
        "cs": ["cz"],
        "sk": ["sk"],
        "hu": ["hu"],
        "ro": ["ro"],

        // Nordics
        "sv": ["se"],
        "no": ["no"],
        "da": ["dk"],
        "fi": ["fi"],
        "is": ["is"],

        // Benelux + lowlands
        "nl-NL": ["nl"],
        "nl-BE": ["be"],

        // Middle East / Africa
        "ar-SA": ["sa"],
        "he": ["il"],
        "tr": ["tr"],
        "tr-TR": ["tr"],

        // Greek
        "el": ["gr"],

        // Misc
        "vi": ["vn"],
        "th": ["th"],
        "id": ["id"],
        "ms": ["my"],
        "ca": ["es"],          // Catalan — Spain storefront
    ]

    /// Returns the storefront codes (lowercased) for the given ASC locale, or
    /// an empty array when the locale isn't mapped.
    static func storefronts(for locale: String) -> [String] {
        table[locale] ?? []
    }
}

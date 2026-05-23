// Lowercase ISO 3166-1 alpha-2 codes for every App Store storefront (175
// territories). Verified against Apple's official "App Store Pricing and
// Availability Start Times by Country or Region" page.
export const APP_STORE_COUNTRIES: readonly string[] = [
  'af', 'al', 'dz', 'ao', 'ai', 'ag', 'ar', 'am', 'au', 'at', 'az',
  'bs', 'bh', 'bb', 'by', 'be', 'bz', 'bj', 'bm', 'bt', 'bo', 'ba', 'bw', 'br', 'vg', 'bn', 'bg', 'bf',
  'kh', 'cm', 'ca', 'cv', 'ky', 'td', 'cl', 'cn', 'co', 'cd', 'cg', 'cr', 'ci', 'hr', 'cy', 'cz',
  'dk', 'dm', 'do', 'ec', 'eg', 'sv', 'ee', 'sz', 'fj', 'fi', 'fr',
  'ga', 'gm', 'ge', 'de', 'gh', 'gr', 'gd', 'gt', 'gw', 'gy',
  'hn', 'hk', 'hu', 'is', 'in', 'id', 'iq', 'ie', 'il', 'it',
  'jm', 'jp', 'jo', 'kz', 'ke', 'xk', 'kw', 'kg',
  'la', 'lv', 'lb', 'lr', 'ly', 'lt', 'lu',
  'mo', 'mg', 'mw', 'my', 'mv', 'ml', 'mt', 'mr', 'mu', 'mx', 'fm', 'md', 'mn', 'me', 'ms', 'ma', 'mz', 'mm',
  'na', 'nr', 'np', 'nl', 'nz', 'ni', 'ng', 'mk', 'no',
  'om', 'pk', 'pw', 'pa', 'pg', 'py', 'pe', 'ph', 'pl', 'pt',
  'qa', 'kr', 'ro', 'ru', 'rw',
  'st', 'sa', 'sn', 'rs', 'sc', 'sl', 'sg', 'sk', 'si', 'sb', 'za', 'es', 'lk', 'kn', 'lc', 'vc', 'sr', 'se', 'ch',
  'tw', 'tj', 'tz', 'th', 'to', 'tt', 'tn', 'tr', 'tm', 'tc',
  'ug', 'ua', 'ae', 'gb', 'us', 'uy', 'uz',
  'vu', 've', 'vn', 'ye', 'zm', 'zw',
];

// Apple-preferred display overrides where Intl.DisplayNames either diverges
// from Apple's storefront naming or returns no value at all (e.g. XK).
const APP_STORE_COUNTRY_NAME_OVERRIDES: Record<string, string> = {
  cd: 'Congo, Democratic Republic of the',
  cg: 'Congo, Republic of the',
  xk: 'Kosovo',
  sz: 'Eswatini',
  tr: 'Türkiye',
  kr: 'Republic of Korea',
  cn: 'China mainland',
};

const intl = new Intl.DisplayNames(['en'], { type: 'region' });

export function appStoreCountryName(cc: string): string {
  const lower = cc.toLowerCase();
  const override = APP_STORE_COUNTRY_NAME_OVERRIDES[lower];
  if (override) return override;
  try {
    return intl.of(cc.toUpperCase()) ?? cc.toUpperCase();
  } catch {
    return cc.toUpperCase();
  }
}

export function isAppStoreCountry(cc: string): boolean {
  return APP_STORE_COUNTRIES.includes(cc.toLowerCase());
}

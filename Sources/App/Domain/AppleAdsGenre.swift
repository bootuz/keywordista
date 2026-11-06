/// Maps an app's iTunes primary genre ID to the genre names Apple's
/// search-term popularity endpoint accepts.
///
/// Apple's list (query-app-search-term-popularity-data, checked 2026-11-06):
/// BUSINESS, EDUCATION, ENTERTAINMENT, FINANCE, FOOD_DRINK, GAMES,
/// HEALTH_FITNESS, LIFESTYLE, NEW_PUBLICATION, PHOTO_VIDEO,
/// PRODUCTIVITY_UTILITIES, SHOPPING, SOCIAL_NETWORKING, SPORTS, TRAVEL.
///
/// Genres Apple doesn't rank (Music, Medical, Navigation, Weather, …) map to
/// nil, which skips popularity for that app rather than borrowing another
/// genre's ranking. NEW_PUBLICATION isn't mapped: which iTunes genres it
/// covers isn't documented.
enum AppleAdsGenre {
    private static let byITunesId: [Int: String] = [
        6000: "BUSINESS",
        6017: "EDUCATION",
        6016: "ENTERTAINMENT",
        6015: "FINANCE",
        6023: "FOOD_DRINK",
        6014: "GAMES",
        6013: "HEALTH_FITNESS",
        6012: "LIFESTYLE",
        6008: "PHOTO_VIDEO",
        6007: "PRODUCTIVITY_UTILITIES",
        6002: "PRODUCTIVITY_UTILITIES",
        6024: "SHOPPING",
        6005: "SOCIAL_NETWORKING",
        6004: "SPORTS",
        6003: "TRAVEL",
    ]

    static func forITunesGenreId(_ id: Int?) -> String? {
        guard let id else { return nil }
        // Game subgenres (Action, Puzzle, …) are 7001–7019.
        if (7001...7019).contains(id) { return "GAMES" }
        return byITunesId[id]
    }
}

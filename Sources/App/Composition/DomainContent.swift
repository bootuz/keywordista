import Vapor

// Vapor `Content` conformance for domain DTOs lives here so the Domain layer
// itself depends only on Foundation. If the domain ever needs to serve a
// non-HTTP transport, only this file changes.
extension DashboardRow: Content {}
extension TopResultDTO: Content {}
extension HistoryPoint: Content {}
extension AppKeywordRow: Content {}
extension CompetitorGapRow: Content {}
extension KeywordOpportunity: Content {}
extension LintFinding: Content {}
extension ASCStatus: Content {}
extension ASAStatus: Content {}
extension QueueStatus: Content {}

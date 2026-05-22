// Mirrors Sources/App/Domain/DomainTypes.swift.
// Keep in sync manually — small surface, low churn.

export interface WatchedApp {
  id: string;
  appStoreId: number;
  bundleId: string;
  name: string;
  iconURL: string | null;
  addedAt: string | null;
}

export interface Keyword {
  id: string;
  term: string;
  countryCode: string;
  createdAt: string | null;
}

export interface TopResultDTO {
  position: number;
  appStoreId: number;
  name: string;
  iconURL: string | null;
}

export interface DashboardRow {
  keywordId: string;
  term: string;
  countryCode: string;
  watchedAppId: string;
  watchedAppName: string;
  rank: number | null;
  // The rank from the previous check, for delta rendering. Null = previous
  // check had no rank (outside top 200). Use hasPreviousCheck to distinguish
  // from "no previous check at all".
  previousRank: number | null;
  hasPreviousCheck: boolean;
  difficulty: number;
  entryBarrier: number;
  checkedAt: string | null;
  topResults: TopResultDTO[];
}

export interface HistoryPoint {
  checkedAt: string;
  rank: number | null;
  difficulty: number;
  entryBarrier: number;
}

export interface AppKeywordRow {
  keywordId: string;
  term: string;
  countryCode: string;
  rank: number | null;
  difficulty: number;
  entryBarrier: number;
  checkedAt: string | null;
}

// Settings DTOs — what the API returns. Secrets never come back; the server
// only tells us whether they're present.
export interface ASCStatus {
  keyId: string | null;
  issuerId: string | null;
  hasPrivateKey: boolean;
  configured: boolean;
}

export interface ASAStatus {
  clientId: string | null;
  orgId: string | null;
  hasClientSecret: boolean;
  configured: boolean;
}

export interface RefreshResponse {
  enqueued: number;
}

export interface QueueStatus {
  pending: number;
}

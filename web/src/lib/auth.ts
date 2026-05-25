// Typed client for the auth + user-management API surface
// (Sources/App/Auth/*.swift). Mirrors the per-controller boundaries:
//
//   AuthController  → getAuthState, setupAdmin, login, logout,
//                     validateInvite, acceptInvite
//   UsersController → listUsers, inviteUser, revokeUser, changeRole
//
// Every function here reuses api.ts's apiFetch wrapper — same JSON
// encoding, same 204 handling, same ApiError surface — so a 401 from
// any endpoint flows through one code path (M2.4 adds the redirect).
//
// Note on cookies: the session cookie is HttpOnly + SameSite=Strict
// set by the server. We never read or set it from JS; the browser
// ships it back automatically on every same-origin request. That
// means there's no "Authorization header" plumbing here, by design.

import { apiFetch } from './api';
import type {
  AuthState,
  AuthSuccess,
  InviteCreated,
  InviteSummary,
  UserListItem,
} from './types';

// ── AuthController surface (/api/v1/auth/*) ──────────────────────

/// Cheap state probe used on app boot. Always returns 200; the SPA
/// branches on `.mode` (local → no auth UI), `.firstRun` (server +
/// empty DB → SetupWizard), and `.signedIn` (server + has user →
/// Dashboard, else LoginPage).
export const getAuthState = () =>
  apiFetch<AuthState>('/auth/state');

/// First-run admin creation. Server returns 410 if any user already
/// exists — callers should treat 410 as "race condition, push to
/// /login instead." The success path sets a session cookie.
///
/// M3.21: when the deployment was booted with KEYWORDISTA_SETUP_TOKEN,
/// the request must carry it in `X-Keywordista-Setup-Token`. The SPA
/// learns this is required via getAuthState().setupTokenRequired and
/// passes the operator-supplied value via the `setupToken` arg.
/// Server returns 401 if the token is missing/wrong.
export const setupAdmin = (
  email: string,
  password: string,
  setupToken?: string,
) =>
  apiFetch<AuthSuccess>('/auth/setup', {
    method: 'POST',
    headers: setupToken
      ? { 'X-Keywordista-Setup-Token': setupToken }
      : undefined,
    body: JSON.stringify({ email, password }),
  });

/// Generic 401 on any failure (server doesn't distinguish "user not
/// found" from "wrong password" — that's the anti-enumeration design).
/// Success path sets a session cookie.
export const login = (email: string, password: string) =>
  apiFetch<AuthSuccess>('/auth/login', {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  });

/// Idempotent — always returns 204, even if there was no session. The
/// server DELETEs the AuthSession row and emits a clearing cookie.
export const logout = () =>
  apiFetch<void>('/auth/logout', { method: 'POST' });

/// Pre-validate an invite token without consuming it. Status codes:
/// 200 + summary, 404 unknown, 410 already accepted, 422 expired,
/// 400 malformed. M2.7 uses this to render "Invalid link" / etc. up
/// front instead of after a failed POST.
export const validateInvite = (token: string) =>
  apiFetch<InviteSummary>(`/auth/invite/${encodeURIComponent(token)}`);

/// Consume an invite. Email is required for open invites (no pinned
/// email at create time); optional but validated for pinned ones.
/// Success path sets a session cookie + creates the user.
export const acceptInvite = (token: string, password: string, email?: string) =>
  apiFetch<AuthSuccess>('/auth/accept-invite', {
    method: 'POST',
    body: JSON.stringify({ token, password, ...(email ? { email } : {}) }),
  });

// ── UsersController surface (/api/v1/users/*, admin-only) ────────

/// Lists every user in the deployment. 403 for non-admin members.
export const listUsers = () =>
  apiFetch<UserListItem[]>('/users');

/// Issues an invite. `email` is optional — when omitted the invite
/// is "open" (anyone with the link can claim it; they supply their
/// own email at accept time). When supplied, the invite is pinned
/// to that address.
export const inviteUser = (role: 'admin' | 'member', email?: string) =>
  apiFetch<InviteCreated>('/users/invite', {
    method: 'POST',
    body: JSON.stringify({ role, ...(email ? { email } : {}) }),
  });

/// Deletes a user. Server returns 409 if you'd revoke yourself OR
/// the only remaining admin — both safeguards live in the
/// controller. Callers should surface those 409 messages directly.
export const revokeUser = (id: string) =>
  apiFetch<void>(`/users/${id}`, { method: 'DELETE' });

/// Changes a user's role. Same 409 safeguards as revoke (can't
/// demote the only admin, can't demote yourself out of admin).
export const changeRole = (id: string, role: 'admin' | 'member') =>
  apiFetch<UserListItem>(`/users/${id}`, {
    method: 'PATCH',
    body: JSON.stringify({ role }),
  });

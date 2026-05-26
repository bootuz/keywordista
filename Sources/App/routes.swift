import Vapor

/// Route table. Mode-conditional (M1.10): local mode keeps the
/// pre-M1 flat shape (no auth, every controller reachable on
/// 127.0.0.1); server mode adds AuthMiddleware on top and gates
/// admin-only endpoints behind RoleMiddleware.requireAdmin.
///
/// **Always public** (both modes, no middleware):
///   • GET    /health
///   • GET    /api/v1/version
///   • POST   /api/v1/auth/setup            — first-run admin creation
///   • POST   /api/v1/auth/login            — credentials → cookie
///   • POST   /api/v1/auth/logout           — clears cookie + DB row
///   • POST   /api/v1/auth/accept-invite    — token + password
///   • GET    /api/v1/auth/state            — { firstRun, signedIn, user? }
///
/// **Local mode** — every API controller reachable directly under
/// /api/v1, identical to pre-M1.
///
/// **Server mode**:
///   • Authenticated (AuthMiddleware): /apps, /keywords, /dashboard,
///     /charts (i.e. the actual product surface).
///   • Admin (AuthMiddleware → RoleMiddleware.requireAdmin):
///     /settings/* (rotating ASC keys is a privileged action) and
///     /users/* (invite/revoke/role-change).
///
/// **Known v1 quirk**: putting the whole SettingsController behind
/// admin means non-admin members hitting the dashboard's call to
/// /settings/asc/keywords (which enriches dashboard rows with the
/// developer's own keyword list) will get 403. The dashboard
/// frontend tolerates that (swallows the error, hides the
/// enrichment row). A follow-up M-task can split SettingsController
/// into read-public + write-admin if the UX warrants it.
func routes(_ app: Application, manifest: Manifest) throws {

    // ── Always public ──────────────────────────────────────────────

    app.get("health") { _ in
        ["status": "ok"]
    }

    let api = app.grouped("api", "v1")
    try api.register(collection: VersionController())

    // Auth flow — public by necessity (you can't require auth to
    // sign in). Same routes registered in both modes; in local mode
    // the setup/login/logout/accept-invite handlers are functionally
    // moot (no User rows exist) but /state still returns useful
    // { mode: "local", firstRun: false, signedIn: false, user: nil }
    // so the SPA can hide all auth UI entirely without probing.
    let authController = AuthController(
        hasher: try PasswordHasher(cost: try manifest.require(EnvVars.bcryptCost)),
        sessionTTLDays: try manifest.require(EnvVars.sessionTTLDays),
        inviteTTLDays: try manifest.require(EnvVars.inviteTTLDays),
        mode: manifest.mode
        // M3.25: M3.21's setupToken arg removed alongside the /setup
        // endpoint deletion. Admin creation moved to the
        // `keywordista createsuperuser` CLI subcommand.
    )
    authController.register(on: api.grouped("auth"))

    // ── Mode-conditional product surface ───────────────────────────

    switch manifest.mode {
    case .local:
        // Local mode: no auth middleware, no admin gating. The Mac
        // menubar app is the sole client; binding to 127.0.0.1
        // already excludes everyone but the local user (M0.4 wires
        // that bind), so an extra cookie dance would only add
        // friction without adding security.
        try api.register(collection: AppsController())
        try api.register(collection: KeywordsController())
        try api.register(collection: DashboardController())
        try api.register(collection: SettingsController())
        try api.register(collection: ChartsController())
        // Backup endpoint (M1.11) — registered in both modes so the
        // cockpit's BackupDownloader (M5) has one code path that
        // works against local OR remote instances. In local mode
        // it's under /api/v1/admin (no auth); in server mode it's
        // gated by RoleMiddleware.requireAdmin below.
        BackupController().register(on: api.grouped("admin"))

    case .server:
        // Server mode: every API call needs a valid session cookie.
        let authenticated = api.grouped(
            AuthMiddleware(sessionTTLDays: try manifest.require(EnvVars.sessionTTLDays))
        )
        // Any signed-in user can read+mutate the team's apps,
        // keywords, dashboard, charts.
        try authenticated.register(collection: AppsController())
        try authenticated.register(collection: KeywordsController())
        try authenticated.register(collection: DashboardController())
        try authenticated.register(collection: ChartsController())

        // Admin-only: settings (ASC/ASA secret rotation) and user
        // management. RoleMiddleware composes AFTER AuthMiddleware,
        // so the admin group inherits auth-required behavior.
        let admin = authenticated.grouped(RoleMiddleware.requireAdmin())
        try admin.register(collection: SettingsController())

        let usersController = UsersController(
            publicBaseURL: try manifest.require(EnvVars.publicBaseURL),
            inviteTTLDays: try manifest.require(EnvVars.inviteTTLDays)
        )
        usersController.register(on: admin.grouped("users"))

        // Backup endpoint (M1.11) — admin-only in server mode. See
        // the local-mode comment above for why this is registered
        // in both modes.
        BackupController().register(on: admin.grouped("admin"))
    }
}

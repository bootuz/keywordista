import Vapor

func routes(_ app: Application) throws {
    app.get("health") { _ in
        ["status": "ok"]
    }

    // No auth: the server binds to 127.0.0.1 only and is supervised by the
    // local menubar app. Anything on this machine that could send an HTTP
    // request can already read the SQLite file directly, so a bearer token
    // never added defense in depth — only friction. See Phase 5b in the
    // project plan for the full reasoning.
    let api = app.grouped("api", "v1")
    try api.register(collection: AppsController())
    try api.register(collection: KeywordsController())
    try api.register(collection: DashboardController())
    try api.register(collection: SettingsController())
    try api.register(collection: VersionController())
    try api.register(collection: ChartsController())
}

import Foundation

/// Hardcoded catalog of Render's regions, web-service plans, Postgres
/// plans, and disk sizes. **Render does NOT expose these via an API
/// endpoint** — there's no `GET /regions` or `GET /plans`. The
/// dashboard hardcodes them too. We mirror what their pricing page
/// publishes; if Render renames/reprices we update this file.
///
/// **Pricing is display-time only** — Render's billing is the actual
/// source of truth. We show "$7/mo" so the user has expectations
/// before the deploy; the bill they get from Render is the bill they
/// pay. Verify periodically against https://render.com/pricing.
///
/// All cost values are integer cents to avoid float drift through
/// the Money type.
enum RenderCatalog {

    // ── Regions ──────────────────────────────────────────────────────
    //
    // Documented at https://render.com/docs/regions. Five public regions
    // as of 2026Q2. Display names are ours — Render's API just exposes
    // the slugs (oregon, frankfurt, etc.) without human-readable names.

    static let regions: [Region] = [
        Region(id: "oregon", displayName: "Oregon (US West)"),
        Region(id: "ohio", displayName: "Ohio (US East)"),
        Region(id: "virginia", displayName: "Virginia (US East)"),
        Region(id: "frankfurt", displayName: "Frankfurt (Europe)"),
        Region(id: "singapore", displayName: "Singapore (Asia)"),
    ]

    // ── Web service plans ────────────────────────────────────────────
    //
    // Render's web service tiers. Sorted cheapest-first; index 0
    // (Starter) is the recommended default for Keywordista — fits
    // comfortably in 512MB RAM with one worker. Standard+ are
    // headroom for teams running 5+ apps.
    //
    // Pricing per https://render.com/pricing (verify quarterly).

    static let webServicePlans: [Plan] = [
        Plan(
            id: "starter",
            displayName: "Starter",
            monthlyCostCents: 700,
            descriptionShort: "0.5 CPU · 512 MB RAM"
        ),
        Plan(
            id: "standard",
            displayName: "Standard",
            monthlyCostCents: 2500,
            descriptionShort: "1 CPU · 2 GB RAM"
        ),
        Plan(
            id: "pro",
            displayName: "Pro",
            monthlyCostCents: 8500,
            descriptionShort: "2 CPU · 4 GB RAM"
        ),
        Plan(
            id: "pro_plus",
            displayName: "Pro Plus",
            monthlyCostCents: 17500,
            descriptionShort: "4 CPU · 8 GB RAM"
        ),
    ]

    // ── Managed Postgres plans ───────────────────────────────────────
    //
    // The `basic_*` family is the cheapest. We expose just three of the
    // 28 documented plans — anyone needing pro/accelerated tiers can
    // hand-edit the deployment or use external Postgres.

    static let postgresPlans: [Plan] = [
        Plan(
            id: "basic_256mb",
            displayName: "Basic 256 MB",
            monthlyCostCents: 600,
            descriptionShort: "256 MB RAM, 1 GB storage"
        ),
        Plan(
            id: "basic_1gb",
            displayName: "Basic 1 GB",
            monthlyCostCents: 1900,
            descriptionShort: "1 GB RAM, 4 GB storage"
        ),
        Plan(
            id: "basic_4gb",
            displayName: "Basic 4 GB",
            monthlyCostCents: 5000,
            descriptionShort: "4 GB RAM, 16 GB storage"
        ),
    ]

    // ── Persistent disk sizes ────────────────────────────────────────
    //
    // Render charges $0.25/GB/month on persistent disks attached to web
    // services. We expose four sensible sizes; the user can opt for
    // managed Postgres if they outgrow this.

    static let diskSizes: [DiskSize] = [
        DiskSize(sizeGB: 1, monthlyCostCents: 25),     // $0.25
        DiskSize(sizeGB: 5, monthlyCostCents: 125),    // $1.25
        DiskSize(sizeGB: 10, monthlyCostCents: 250),   // $2.50
        DiskSize(sizeGB: 20, monthlyCostCents: 500),   // $5.00
    ]

    // ── Postgres version ─────────────────────────────────────────────
    //
    // Render supports Postgres 11 through 18. We default to 16 (the
    // latest GA at time of writing) so the cockpit never has to ask
    // the user which version to pick. They can change it after deploy
    // via Render's dashboard if needed.
    static let defaultPostgresVersion = "16"
}

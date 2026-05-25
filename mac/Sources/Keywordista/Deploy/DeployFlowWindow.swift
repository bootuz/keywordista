import SwiftUI

/// Root view of the deploy wizard window. Branches on
/// `coordinator.phase` to render one of 6 child views. All 6 children
/// observe the same coordinator object, so going back through the
/// wizard preserves form state without prop drilling.
///
/// **Window sizing**: explicit frame(width:height:) because macOS
/// SwiftUI windows otherwise expand to fit content + scrollbars,
/// which makes a multi-step wizard awkward. 580×680 fits all six
/// screens comfortably without being a giant blob on a 13" laptop.
struct DeployFlowWindow: View {
    @ObservedObject var coordinator: DeployFlowCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Progress strip: shows which of the 5 user-facing steps
            // we're on (deploying/success/failed share the last slot).
            StepHeader(phase: coordinator.phase)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            Group {
                switch coordinator.phase {
                case .pickProvider:
                    ProviderPickerView(coordinator: coordinator)
                case .authenticate:
                    AuthenticateView(coordinator: coordinator)
                case .configure:
                    ConfigureView(coordinator: coordinator)
                case .confirm:
                    ConfirmView(coordinator: coordinator)
                case .deploying:
                    DeployingView(coordinator: coordinator)
                case .success:
                    SuccessView(coordinator: coordinator)
                case .failed:
                    FailedView(coordinator: coordinator)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 580, height: 680)
    }
}

// MARK: - Step header

/// Six-dot horizontal progress indicator. Filled circle = current step,
/// hollow = upcoming, checkmark = completed. Skips ahead for the
/// terminal states (success/failed both show the final slot lit).
private struct StepHeader: View {
    let phase: DeployFlowPhase

    private var stepIndex: Int {
        switch phase {
        case .pickProvider: return 0
        case .authenticate: return 1
        case .configure: return 2
        case .confirm: return 3
        case .deploying, .success, .failed: return 4
        }
    }

    private let labels = ["Pick host", "Authenticate", "Configure", "Confirm", "Deploy"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<labels.count, id: \.self) { i in
                HStack(spacing: 6) {
                    Circle()
                        .fill(i <= stepIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(labels[i])
                        .font(.caption)
                        .foregroundStyle(i == stepIndex ? .primary : .secondary)
                }
                if i < labels.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                }
            }
        }
    }
}

// MARK: - Step 1: Pick provider

private struct ProviderPickerView: View {
    @ObservedObject var coordinator: DeployFlowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Where do you want to deploy?")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Pick a host. You'll need an account with the provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Sort first-class providers to top so "recommended"
            // tier visually leads.
            let sorted = coordinator.providers.sorted { lhs, rhs in
                supportRank(lhs.supportLevel) < supportRank(rhs.supportLevel)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(0..<sorted.count, id: \.self) { i in
                        ProviderCard(provider: sorted[i]) {
                            coordinator.selectProvider(sorted[i])
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            Spacer()
        }
    }

    private func supportRank(_ s: ProviderSupport) -> Int {
        switch s {
        case .firstClass: return 0
        case .templateLink: return 1
        case .docsOnly: return 2
        }
    }
}

private struct ProviderCard: View {
    let provider: any Provider
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(provider.displayName)
                            .font(.headline)
                        SupportBadge(level: provider.supportLevel)
                    }
                    Text(provider.marketingTagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct SupportBadge: View {
    let level: ProviderSupport

    var body: some View {
        switch level {
        case .firstClass:
            Label("Recommended", systemImage: "star.fill")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
        case .templateLink:
            Text("Browser handoff")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        case .docsOnly:
            Text("Advanced")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
    }
}

// MARK: - Step 2: Authenticate

private struct AuthenticateView: View {
    @ObservedObject var coordinator: DeployFlowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in to \(coordinator.selectedProvider?.displayName ?? "the provider")")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Paste an API key. We store it in your Mac's Keychain — it never leaves this machine except to call the provider's API.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 8) {
                Text("API key")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField(
                    "rnd_…",
                    text: $coordinator.token,
                    onCommit: triggerAuthenticate
                )
                .textFieldStyle(.roundedBorder)
                .disabled(coordinator.authenticating)
                .onChange(of: coordinator.token) { _ in
                    // Clear stale error so the user isn't yelled at
                    // for a typo they just started fixing.
                    // macOS 13-compatible signature (one-arg closure).
                    coordinator.authError = nil
                }

                if let detail = coordinator.authError {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Link(
                    "Get an API key →",
                    destination: providerKeyURL()
                )
                .font(.caption)
            }
            .padding(.horizontal, 24)

            Spacer()

            FooterBar(
                onBack: { coordinator.goBack() },
                onPrimary: triggerAuthenticate,
                primaryLabel: coordinator.authenticating ? "Validating…" : "Continue →",
                primaryDisabled: coordinator.token.isEmpty || coordinator.authenticating
            )
        }
    }

    private func triggerAuthenticate() {
        Task { await coordinator.authenticate() }
    }

    private func providerKeyURL() -> URL {
        switch coordinator.selectedProvider?.kind {
        case .render: return URL(string: "https://dashboard.render.com/u/settings?add-api-key")!
        case .fly: return URL(string: "https://fly.io/user/personal_access_tokens")!
        default: return URL(string: "https://example.com")!
        }
    }
}

// MARK: - Step 3: Configure

private struct ConfigureView: View {
    @ObservedObject var coordinator: DeployFlowCoordinator
    @State private var validationError: String?

    /// Live-validated service-name error from the selected provider's
    /// rules. Recomputed on every coordinator.serviceName change
    /// (SwiftUI re-evaluates body when @Published fires). Empty input
    /// shows no error (don't yell at the user before they type).
    private var serviceNameError: String? {
        guard !coordinator.serviceName.isEmpty,
              let provider = coordinator.selectedProvider else { return nil }
        return provider.validateServiceName(coordinator.serviceName).errorMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Configure your deployment")
                    .font(.title3)
                    .fontWeight(.semibold)
                if let owner = coordinator.account?.displayName {
                    Text("Owner: \(owner)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    formRow("Service name") {
                        TextField("studio-prod", text: $coordinator.serviceName)
                            .textFieldStyle(.roundedBorder)
                        // Live per-keystroke validation via the selected
                        // provider's rules. Shown red below the field so
                        // the user knows the problem BEFORE hitting
                        // Continue — and the Continue button's
                        // primaryDisabled below also reads from this.
                        if let nameError = serviceNameError {
                            Text(nameError)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    formRow("Region") {
                        Picker("", selection: $coordinator.selectedRegion) {
                            ForEach(coordinator.regions) { region in
                                Text(region.displayName).tag(Optional(region))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    formRow("Plan") {
                        Picker("", selection: $coordinator.selectedPlan) {
                            ForEach(coordinator.plans) { plan in
                                Text("\(plan.displayName) — \(Money.usd(plan.monthlyCostCents).formatted)/mo")
                                    .tag(Optional(plan))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    DatabasePicker(coordinator: coordinator)

                    formRow("Admin email") {
                        TextField("you@studio.local", text: $coordinator.adminEmail)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            FooterBar(
                onBack: { coordinator.goBack() },
                onPrimary: proceed,
                primaryLabel: "Continue →",
                primaryDisabled: coordinator.serviceName.isEmpty
                    || coordinator.adminEmail.isEmpty
                    || serviceNameError != nil
            )
        }
    }

    private func proceed() {
        validationError = nil
        do {
            try coordinator.proceedToConfirm()
        } catch {
            validationError = (error as? DeployFlowError)?.description ?? "\(error)"
        }
    }

    @ViewBuilder
    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct DatabasePicker: View {
    @ObservedObject var coordinator: DeployFlowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Database")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(coordinator.databases) { option in
                DatabaseOptionRow(
                    option: option,
                    isSelected: isSelected(option),
                    onSelect: { selectDefault(for: option) }
                )
            }

            // External-Postgres URL field, only when that option is picked.
            if case .externalPostgres = coordinator.selectedDatabase {
                TextField(
                    "postgres://user:pass@host:5432/db",
                    text: $coordinator.externalPostgresURL
                )
                .textFieldStyle(.roundedBorder)
                .padding(.top, 4)
            }
        }
    }

    private func isSelected(_ option: DatabaseOption) -> Bool {
        switch (option, coordinator.selectedDatabase) {
        case (.sqliteOnDisk, .sqliteOnDisk): return true
        case (.providerManagedPostgres, .providerManagedPostgres): return true
        case (.externalPostgres, .externalPostgres): return true
        default: return false
        }
    }

    private func selectDefault(for option: DatabaseOption) {
        switch option {
        case .sqliteOnDisk(let sizes):
            coordinator.selectedDatabase = .sqliteOnDisk(
                size: sizes.first ?? DiskSize(sizeGB: 1, monthlyCostCents: 25)
            )
        case .providerManagedPostgres(let plans):
            coordinator.selectedDatabase = .providerManagedPostgres(
                plan: plans.first ?? Plan(
                    id: "basic_256mb", displayName: "Basic",
                    monthlyCostCents: 600, descriptionShort: ""
                )
            )
        case .externalPostgres:
            coordinator.selectedDatabase = .externalPostgres(connectionURL: "")
        }
    }
}

private struct DatabaseOptionRow: View {
    let option: DatabaseOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch option {
        case .sqliteOnDisk: return "SQLite on persistent disk"
        case .providerManagedPostgres: return "Provider-managed Postgres"
        case .externalPostgres: return "External Postgres"
        }
    }

    private var subtitle: String {
        switch option {
        case .sqliteOnDisk(let sizes):
            let cheapest = sizes.first.map { Money.usd($0.monthlyCostCents).formatted } ?? ""
            return "Cheapest. From \(cheapest)/mo for 1 GB."
        case .providerManagedPostgres(let plans):
            let cheapest = plans.first.map { Money.usd($0.monthlyCostCents).formatted } ?? ""
            return "Managed backups + point-in-time recovery. From \(cheapest)/mo."
        case .externalPostgres:
            return "Use your own Neon / Supabase / RDS / self-hosted Postgres."
        }
    }
}

// MARK: - Step 4: Confirm

private struct ConfirmView: View {
    @ObservedObject var coordinator: DeployFlowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review and deploy")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("\(coordinator.selectedProvider?.displayName ?? "Provider") will charge your account:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if let confirmation = coordinator.confirmation {
                VStack(alignment: .leading, spacing: 14) {
                    CostBreakdown(spec: confirmation.spec, total: confirmation.estimatedMonthlyCost)
                    Divider()
                    SpecSummary(spec: confirmation.spec)
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            Text("Keywordista doesn't charge you anything — that's all the provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            FooterBar(
                onBack: { coordinator.goBack() },
                onPrimary: { Task { await coordinator.deploy() } },
                primaryLabel: "Deploy ↑",
                primaryDisabled: false
            )
        }
    }
}

private struct CostBreakdown: View {
    let spec: DeploymentSpec
    let total: Money

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            costRow(label: "\(spec.plan.displayName) web service",
                    money: Money.usd(spec.plan.monthlyCostCents))
            switch spec.database {
            case .sqliteOnDisk(let size):
                costRow(label: "Persistent disk (\(size.sizeGB) GB)",
                        money: Money.usd(size.monthlyCostCents))
            case .providerManagedPostgres(let plan):
                costRow(label: "Managed Postgres (\(plan.displayName))",
                        money: Money.usd(plan.monthlyCostCents))
            case .externalPostgres:
                costRow(label: "External Postgres", money: .zero, secondary: "you pay your provider directly")
            }
            Divider().padding(.vertical, 2)
            HStack {
                Text("Total")
                    .font(.callout)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(total.formatted)/mo")
                    .font(.callout)
                    .fontWeight(.semibold)
            }
        }
    }

    private func costRow(label: String, money: Money, secondary: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout)
                if let secondary {
                    Text(secondary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(money.formatted)/mo").font(.callout)
        }
    }
}

private struct SpecSummary: View {
    let spec: DeploymentSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Service name", spec.serviceName)
            row("Region", spec.region.displayName)
            row("Image", spec.imageRef)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Step 5: Deploying

private struct DeployingView: View {
    @ObservedObject var coordinator: DeployFlowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(coordinator.currentDeployStatus)
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                Text("This usually takes 60–120 seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(coordinator.deployEvents.indices, id: \.self) { i in
                            DeployEventRow(event: coordinator.deployEvents[i])
                                .id(i)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
                .onChange(of: coordinator.deployEvents.count) { count in
                    // Auto-scroll to the newest event as they stream in.
                    // macOS 13-compatible signature (one-arg closure).
                    if count > 0 {
                        withAnimation {
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }

            HStack {
                Button("Cancel", role: .destructive) {
                    Task { await coordinator.cancel() }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Cancelling will destroy any provisioned resources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.secondary.opacity(0.05))
        }
    }
}

private struct DeployEventRow: View {
    let event: DeployEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
                .frame(width: 14)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
        }
    }

    private var icon: String {
        switch event {
        case .statusChanged: return "arrow.right.circle"
        case .logLine: return "doc.text"
        case .healthCheckPassed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch event {
        case .statusChanged: return .accentColor
        case .logLine: return .secondary
        case .healthCheckPassed: return .green
        case .failed: return .red
        }
    }

    private var text: String {
        switch event {
        case .statusChanged(let s): return s
        case .logLine(let s): return s
        case .healthCheckPassed: return "Health check passed"
        case .failed(let r): return "Failed: \(r)"
        }
    }
}

// MARK: - Step 6a: Success

private struct SuccessView: View {
    @ObservedObject var coordinator: DeployFlowCoordinator
    @State private var passwordCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let ctx = coordinator.successContext {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title2)
                        Text("Your Keywordista is live!")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Group {
                        Text("URL").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(ctx.publicURL.absoluteString)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Copy") {
                                copyToClipboard(ctx.publicURL.absoluteString)
                            }
                            Button("Open") {
                                NSWorkspace.shared.open(ctx.publicURL)
                            }
                        }
                    }

                    Divider()

                    // Cost recap so the user has a concrete "what
                    // I'm being charged" line on the success screen,
                    // not just in the now-dismissed Confirm step.
                    HStack(spacing: 6) {
                        Image(systemName: "creditcard")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(ctx.providerDisplayName) will bill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(ctx.estimatedMonthlyCost.formatted)/mo")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("for this deployment.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    // The plaintext admin password lives here ONCE.
                    // The "save this now" banner is intentionally loud.
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Save this password now — we won't show it again.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)

                        Text("Admin login").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(ctx.adminEmail)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                        }
                        HStack {
                            Text(ctx.adminPassword)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button(passwordCopied ? "✓ Copied" : "Copy password") {
                                copyToClipboard(ctx.adminPassword)
                                passwordCopied = true
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
            }

            FooterBar(
                onBack: nil,    // No back from success — flow is committed
                onPrimary: { coordinator.complete() },
                primaryLabel: "Done",
                primaryDisabled: false
            )
        }
    }

    private func copyToClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

// MARK: - Step 6b: Failure

private struct FailedView: View {
    @ObservedObject var coordinator: DeployFlowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = coordinator.failure {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.title2)
                        Text("Deploy failed")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    Text(failure.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)

                HStack {
                    if failure.retryable {
                        Button("Retry") {
                            // Re-fire deploy() against the same spec.
                            // For non-retryable (e.g. partial), the
                            // user gets only the Close button.
                            coordinator.failure = nil
                            coordinator.phase = .confirm
                        }
                    }
                    Spacer()
                    Button("Close") {
                        Task { await coordinator.cancel() }
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(24)
            }
        }
    }
}

// MARK: - Shared footer bar

private struct FooterBar: View {
    let onBack: (() -> Void)?
    let onPrimary: () -> Void
    let primaryLabel: String
    let primaryDisabled: Bool

    var body: some View {
        HStack {
            if let onBack {
                Button("← Back", action: onBack)
            }
            Spacer()
            Button(primaryLabel, action: onPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.secondary.opacity(0.05))
    }
}

import Foundation
import SwiftUI

/// "Add existing deployment" window. The escape hatch for users who
/// deployed via raw Docker / Kubernetes / Render Blueprint / hand-
/// edited render.yaml — anything that didn't go through the cockpit's
/// own deploy flow. They paste their URL + admin credentials and the
/// menubar adopts the instance.
///
/// Two-step verification before committing the instance:
///   1. GET <url>/api/v1/health to prove the URL is a Keywordista
///      backend (returns {"status":"ok"})
///   2. POST <url>/api/v1/auth/login with the supplied credentials
///      to prove admin access AND capture the session cookie for
///      later use
///
/// Either step failing surfaces a specific error rather than letting
/// the user click Add and discover later that "Open Dashboard" 404s.
@MainActor
final class AddExistingCoordinator: ObservableObject {
    @Published var urlString: String = ""
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var inFlight: Bool = false
    @Published var error: String?

    let onCompletion: (Instance, String) -> Void   // (instance, sessionCookie)
    let httpClient: any HTTPClient

    init(
        httpClient: any HTTPClient = URLSession.shared,
        onCompletion: @escaping (Instance, String) -> Void
    ) {
        self.httpClient = httpClient
        self.onCompletion = onCompletion
    }

    var canSubmit: Bool {
        !inFlight
            && URL(string: urlString) != nil
            && !email.isEmpty
            && !password.isEmpty
    }

    /// Runs the two-step verification then commits the instance.
    /// Stays on the form (with `error` set) on any failure.
    func submit() async {
        guard canSubmit, let baseURL = normalizedURL() else { return }
        inFlight = true
        error = nil
        defer { inFlight = false }

        do {
            try await verifyHealth(baseURL: baseURL)
            let cookie = try await login(baseURL: baseURL)

            // Health + login both succeeded → commit. Use a generated
            // displayName from the host; the user can rename later
            // (M5 — for now the menubar shows whatever we pick here).
            let instance = Instance(
                id: UUID(),
                kind: .remote(RemoteInstance(
                    displayName: baseURL.host ?? "Imported deployment",
                    providerKind: .customDockerHost,    // we don't know
                    providerServiceId: "imported",
                    baseURL: baseURL,
                    imageTag: "unknown",
                    createdAt: Date(),
                    providerManagedDatabaseId: nil
                ))
            )
            onCompletion(instance, cookie)
        } catch let importError as AddExistingError {
            error = importError.description
        } catch let unexpected {
            error = "Unexpected error: \(unexpected.localizedDescription)"
        }
    }

    // MARK: - Verification steps

    /// GET /api/v1/health. Expects {"status":"ok"}. Anything else
    /// means the URL isn't a Keywordista backend (typo, dead URL,
    /// someone else's app at that host).
    private func verifyHealth(baseURL: URL) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/health"))
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            throw AddExistingError.unreachable(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AddExistingError.notKeywordista(
                "got HTTP \(status) from \(baseURL.appendingPathComponent("api/v1/health").absoluteString)"
            )
        }

        // Parse to make sure it's our payload shape, not e.g. a
        // captive-portal landing page that happened to return 200.
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["status"] as? String == "ok" else {
            throw AddExistingError.notKeywordista(
                "response didn't look like Keywordista's /health payload"
            )
        }
    }

    /// POST /api/v1/auth/login with the supplied credentials.
    /// Returns the session cookie string for storage in Keychain.
    /// 401 → "wrong credentials"; other failures → generic.
    private func login(baseURL: URL) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password,
        ])

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await httpClient.data(for: request)
        } catch {
            throw AddExistingError.unreachable(error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 {
                throw AddExistingError.invalidCredentials
            }
            throw AddExistingError.loginFailed("HTTP \(status)")
        }

        // Session cookie is in Set-Cookie header. Backend names it
        // `keywordista_session` (per Sources/App/Auth/SessionCookie.swift).
        // URLSession parses cookies into HTTPCookieStorage, so we
        // pull from there rather than reparsing the header string.
        let cookies = HTTPCookieStorage.shared.cookies(for: baseURL) ?? []
        guard let session = cookies.first(where: { $0.name == "keywordista_session" }) else {
            throw AddExistingError.loginFailed("server didn't return a session cookie")
        }
        return session.value
    }

    /// Normalizes the user-typed URL — trims whitespace, prepends
    /// https:// if scheme missing, strips trailing slash.
    private func normalizedURL() -> URL? {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        if raw.hasSuffix("/") { raw = String(raw.dropLast()) }
        return URL(string: raw)
    }
}

enum AddExistingError: Error, CustomStringConvertible {
    case unreachable(String)
    case notKeywordista(String)
    case invalidCredentials
    case loginFailed(String)

    var description: String {
        switch self {
        case .unreachable(let detail):
            return "Couldn't reach that URL: \(detail)"
        case .notKeywordista(let detail):
            return "That URL doesn't look like a Keywordista deployment. \(detail)"
        case .invalidCredentials:
            return "Email or password rejected by the deployment."
        case .loginFailed(let detail):
            return "Login failed: \(detail)"
        }
    }
}

// MARK: - SwiftUI window

struct AddExistingWindow: View {
    @ObservedObject var coordinator: AddExistingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add an existing deployment")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Already deployed Keywordista somewhere? Paste the URL and your admin credentials to track it in the menubar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 14) {
                fieldRow("URL") {
                    TextField("https://kw.studio.com", text: $coordinator.urlString)
                        .textFieldStyle(.roundedBorder)
                        .disabled(coordinator.inFlight)
                }
                fieldRow("Admin email") {
                    TextField("you@studio.local", text: $coordinator.email)
                        .textFieldStyle(.roundedBorder)
                        .disabled(coordinator.inFlight)
                }
                fieldRow("Admin password") {
                    SecureField("•••", text: $coordinator.password)
                        .textFieldStyle(.roundedBorder)
                        .disabled(coordinator.inFlight)
                }

                if let error = coordinator.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            HStack {
                Spacer()
                Button(coordinator.inFlight ? "Verifying…" : "Add deployment") {
                    Task { await coordinator.submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!coordinator.canSubmit)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color.secondary.opacity(0.05))
        }
        .frame(width: 460, height: 360)
    }

    @ViewBuilder
    private func fieldRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

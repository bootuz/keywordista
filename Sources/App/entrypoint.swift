import Foundation
import Vapor
import Logging
import NIOCore
import NIOPosix

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)

        do {
            try await configure(app)
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }

        // M3.25: CLI subcommands signal failure via `ExitCode` (a
        // sysexits.h-aligned enum). Without this catch, throwing
        // ExitCode out of `run()` reaches Swift's @main wrapper,
        // which renders the error as `Fatal error: Error raised at
        // top level: App.ExitCode.X` plus a 30-line backtrace —
        // terrifying when the actual cause was the operator typing
        // a bad email. Catch ExitCode here, shut down cleanly, and
        // exit with the raw value so shells see a meaningful code
        // and operators see only the human-readable message the
        // command already printed.
        do {
            try await app.execute()
        } catch let exitCode as ExitCode {
            try? await app.asyncShutdown()
            Foundation.exit(exitCode.rawValue)
        }
        try await app.asyncShutdown()
    }
}

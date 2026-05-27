import AppKit
import Darwin
import Foundation

// Where the running ServiceSupervisor publishes itself so the
// shutdown delegate can find it. Weak so we don't keep the
// supervisor alive past its real owner (AppCoordinator); the
// supervisor's lifetime is identical to the app's lifetime in
// practice, so this is purely about not muddying ownership.
//
// Why a static registry: NSApplicationDelegateAdaptor instantiates
// the delegate *before* the SwiftUI App body evaluates, so the
// delegate can't take the supervisor in its initializer. The
// alternative — wiring the supervisor via a Scene.onAppear — fires
// only when a window or the MenuBarExtra is shown, which is too
// late for the SIGTERM path during early startup.
@MainActor
enum AppSupervisorRegistry {
    static weak var supervisor: ServiceSupervisor?
}

/// NSApplicationDelegate that drains the spawned Vapor child process
/// before the menubar app exits.
///
/// **Why this exists**: `ServiceSupervisor.stop()` does the SIGTERM-
/// then-SIGKILL escalation correctly, but nothing was calling it on
/// app quit. SwiftUI's default termination flow just exits the
/// parent — the spawned `keywordista-server` keeps running and
/// holds whatever port it picked (8080–8090). The next launch then
/// picks the next port via `resolveFreePort`, and orphans accumulate
/// over a dev day.
///
/// **Termination flow** (Quit / ⌘Q / `osascript … quit`):
///   1. AppKit calls `applicationShouldTerminate(_:)`.
///   2. We return `.terminateLater` and kick off an async task.
///   3. The task awaits `supervisor.stop()` (SIGTERM, wait ≤5s, SIGKILL).
///   4. The task calls `NSApp.reply(toApplicationShouldTerminate: true)`.
///   5. AppKit completes its termination dance and exits.
///
/// Returning `.terminateLater` is critical — without it, AppKit
/// exits the parent before the awaited stop() resolves, and we're
/// back to orphan-land. `applicationWillTerminate` is too late for
/// the same reason (no async escape hatch).
///
/// **SIGTERM / SIGINT**: also handled. `kill <pid>` from the shell
/// (common during dev when iterating on the menubar) would
/// otherwise skip AppKit's termination flow entirely. Routing the
/// signals through `NSApp.terminate(nil)` makes them go through
/// the same applicationShouldTerminate path as a clean Quit, so
/// the child gets stopped either way.
final class AppShutdownDelegate: NSObject, NSApplicationDelegate {

    /// Signal sources must be retained for their lifetime — Dispatch
    /// cancels and deallocates them on the last strong reference.
    /// Holding them here keeps them firing until the process dies.
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            // If no supervisor is registered (defensive — shouldn't happen
            // in production), reply immediately so we don't hang the app
            // on a missing dependency.
            if let supervisor = AppSupervisorRegistry.supervisor {
                await supervisor.stop()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - SIGTERM / SIGINT

    private func installSignalHandlers() {
        // libc would otherwise kill the process synchronously on these
        // signals, racing our Dispatch handler. SIG_IGN tells libc not
        // to act; the Dispatch source we install next picks them up
        // and routes them through NSApp.terminate(nil) → the normal
        // applicationShouldTerminate flow → supervisor.stop().
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        for sig in [SIGTERM, SIGINT] {
            // Use a global queue, not .main. In a Cocoa GUI app the main
            // runloop's interaction with the kqueue signal-delivery
            // mechanism is unreliable — handlers registered on .main
            // routinely fail to fire when the app is idle.
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                // Why we don't call NSApp.terminate(nil) here:
                //
                // When `applicationShouldTerminate` is invoked from inside an
                // outer DispatchQueue.main.async block (which is where we'd
                // have to call NSApp.terminate from), returning .terminateLater
                // puts AppKit into a wait state that doesn't drain subsequent
                // main-queue items — so any `Task { @MainActor in … }` enqueued
                // from applicationShouldTerminate never runs. The supervisor
                // never stops, the app hangs. (Confirmed empirically on
                // macOS 14/15 — file under "AppKit lifecycle quirks".)
                //
                // Instead, drive cleanup directly here and exit(0). We lose
                // applicationWillTerminate notifications to other delegates,
                // but this app has only one cleanup task and we control all
                // of it. The Quit-via-menu path still goes through the proper
                // applicationShouldTerminate flow with .terminateLater.
                DispatchQueue.main.async {
                    Task { @MainActor in
                        await AppSupervisorRegistry.supervisor?.stop()
                        exit(0)
                    }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

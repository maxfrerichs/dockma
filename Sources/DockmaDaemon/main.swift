import DockmaCore
import Foundation

// launchd hands the control service only to the job that declares it, and
// sets XPC_SERVICE_NAME to that job's label.
let paths = Paths.default()
guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LaunchAgent.label(for: paths) else {
    FileHandle.standardError.write(Data("dockmad runs as a launchd job; start it with `dockma start`.\n".utf8))
    exit(64)
}
let daemon = Daemon(paths: paths)
daemon.start()
// Run the main thread's run loop rather than dispatchMain(): with
// dispatchMain() main-queue work runs on a worker thread, which breaks
// @MainActor isolation checks. The port keeps the run loop alive.
RunLoop.main.add(Port(), forMode: .default)
withExtendedLifetime(daemon) { RunLoop.main.run() }

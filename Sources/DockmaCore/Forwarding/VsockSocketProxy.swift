import Foundation

/// Serves a unix socket by piping each connection to a dockma-agent vsock
/// port: ~/.dockma/docker.sock → dockerd, ~/.dockma/shell.sock → shell sessions.
@MainActor
public enum VsockSocketProxy {
    public static func listen(path: String, port: UInt32, host: VMHost) throws -> SocketListener {
        try SocketListener.unix(path: path) { client in
            Task { @MainActor in
                do {
                    let guest = try await host.connect(port: port)
                    SocketCopier.pipe(client, guest)
                } catch {
                    close(client)
                }
            }
        }
    }
}

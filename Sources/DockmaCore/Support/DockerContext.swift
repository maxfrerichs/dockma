import Foundation

/// Registers a `dockma` docker CLI context pointing at the VM's socket.
public enum DockerContext {
    public static let name = "dockma"

    /// Creates the context if the docker CLI exists and the context doesn't.
    /// Returns a note for the user, or nil when nothing needed doing.
    public static func ensure(paths: Paths) -> String? {
        guard let docker = Subprocess.which("docker") else { return nil }
        if let inspect = try? Subprocess.run(docker, arguments: ["context", "inspect", name]), inspect.status == 0 {
            return nil
        }
        let host = "unix://\(paths.dockerSocket.path)"
        guard let result = try? Subprocess.run(docker, arguments: ["context", "create", name, "--description", "dockma VM", "--docker", "host=\(host)"]),
              result.status == 0
        else {
            return "could not create docker context \(name)"
        }
        return "created docker context \(name)"
    }

    public static func remove() {
        guard let docker = Subprocess.which("docker") else { return }
        _ = try? Subprocess.run(docker, arguments: ["context", "rm", "--force", name])
    }

    /// Describes how the docker CLI must be pointed at dockma, or nil if the
    /// environment already does.
    public static func hint(paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let host = "unix://\(paths.dockerSocket.path)"
        if let current = environment["DOCKER_HOST"] {
            if current == host { return nil }
            return "DOCKER_HOST is set to \(current), which overrides docker contexts. Use: export DOCKER_HOST=\(host)"
        }
        return "Use dockma with: docker context use \(name)   (or export DOCKER_HOST=\(host))"
    }
}

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

dockma runs Docker on macOS inside a minimal Linux VM booted with Virtualization.framework. User-facing documentation lives in `README.md`: usage, configuration, the state directory and the architecture diagram. Keep the README in sync when you change CLI flags, defaults, files under `~/.dockma`, or pinned versions.

The project has two halves:
- **Host (Swift).** The `dockma` CLI, plus a long-lived `dockma daemon` that a per-user launchd job (`io.dockma.daemon`) runs. The daemon owns the `VZVirtualMachine`.
- **Guest (`vm/`).** A custom 6.18 LTS kernel, a busybox initramfs, Docker's static binaries and `dockma-agent` (static Go).

## Host–guest protocol

The vsock ports are defined in `VMConfigurationBuilder.Port` and duplicated in `vm/agent/main.go`. Change both together.

| Port | Purpose |
|------|---------|
| 1024 | Byte proxy to `/var/run/docker.sock`. The host serves it as `~/.dockma/docker.sock`. |
| 1025 | JSON-lines control. `AgentMessage` (Swift) mirrors `message` (Go). Guest→host: `hello`, `ports`. Host→guest: `settime`, `shutdown`. |
| 1026 | TCP tunnel. The first line is `tcp <host:port>`; raw bytes follow. |
| 1027 | `dockma shell` sessions. Frames are `[type u8][len u32 BE][payload]`. The types are defined in `ShellFrame` (`Sources/dockma/ShellProtocol.swift`) and mirrored in `vm/agent/shell.go`; change both together. A golden `resize` byte sequence is asserted in both test suites. The host serves this port as `~/.dockma/shell.sock`, and the daemon only proxies bytes. |

The host CLI talks to the daemon over `~/.dockma/control.sock`: one JSON line in (`ControlRequest`), one line out (`DaemonStatus`).

The home directory is shared via virtiofs (tag `home`) and mounted in the guest **at the same host path**. The path is passed percent-encoded as `dockma.home=` on the kernel cmdline and decoded in `rcS`. Rosetta is the virtiofs tag `rosetta`, registered with binfmt_misc using flags `CF`.

## Source map

| Area | Files |
|---|---|
| CLI commands | `Sources/DockmaCLI/Dockma.swift` — all subcommands, plus log tailing and following |
| Daemon lifecycle | `Sources/dockma/Daemon.swift` — boot, signal handling, graceful stop, exit codes, time sync, log rotation |
| VM | `Sources/dockma/VMConfigurationBuilder.swift` (devices, data disk), `VMHost.swift` (VZ wrapper, vsock connect) |
| Forwarding | `Sources/dockma/Forwarding/` — `SocketListener` (unix/TCP accept via dispatch source), `SocketCopier` (bidirectional copy with half-close), `VsockSocketProxy` (unix socket → agent vsock port; docker and shell), `PortForwarder` (reconciles the agent's port set into listeners) |
| Shell client | `ShellProtocol.swift` (frames, incremental decoder), `ShellSession.swift` (raw TTY, SIGWINCH, signal forwarding, stdin/output pumps) |
| Agent link | `AgentClient.swift` (reconnecting control client), `AgentProtocol.swift` |
| launchd and CLI↔daemon | `LaunchAgent.swift`, `ControlProtocol.swift` (also `UnixSocket`, `DockerPing`) |
| Settings and paths | `Config.swift`, `Paths.swift`, `KernelCmdline.swift`, `Entitlements.swift` |
| Guest build | `vm/Dockerfile`, `vm/kernel/dockma.config`, `vm/kernel/check-docker-config.sh` |
| Guest boot | `vm/rootfs/init` (stage 0), `etc/inittab`, `etc/init.d/{rcS,dockerd,shutdown}`, `usr/libexec/dockma-disk` (data disk: format only when blank; tested by `vm/tests/dockma-disk-test.sh` in the guest build), `etc/docker/daemon.json`, `etc/profile` (shell prompt), `usr/share/udhcpc/default.script` |
| Guest agent | `vm/agent/main.go` (servers, control, port watcher), `ports.go` (pure port extraction), `shell.go` (shell sessions on a pty via creack/pty or on pipes) |

## Commands

```sh
make build                # swift build + ad-hoc codesign with dockma.entitlements (required to run the VM)
make install              # signed release binary → ~/.local/bin/dockma (PREFIX=...)
make guest                # build vm/out/{Image,initramfs.cpio.zst} with any arm64 docker (buildx)
make install-guest        # copy guest artifacts to ~/.dockma/guest/
make test                 # swift test (Swift Testing)
make e2e                  # build + scripts/e2e.sh against a real VM (starts/restarts/stops the user's VM)
swift test --filter dockmaTests.planIsEmptyWhenNothingChanged   # one test
```

Agent tests run inside `make guest`, in the Dockerfile's `go vet` and `go test` step. To run them alone:

```sh
tar cf - -C vm agent | docker run --rm -i golang:1.27-alpine sh -c 'tar xf - && cd agent && go test ./...'
```

Changes under `vm/` only take effect after `make guest install-guest` followed by `dockma restart`. Changes to the Swift daemon need `make build` and a restart.

No linter or formatter is configured.

## Gotchas

- **`swift build` and `swift test` strip the entitlement.** Both relink the binary unsigned (`make test` re-signs it afterwards). Without `com.apple.security.virtualization` the daemon can't start a VM, and `dockma start` refuses to run. Always use `make build` or `make install`.
- **launchd runs the binary you started it with.** The plist's `ProgramArguments` is the absolute path of the binary that ran `dockma start`. A later unsigned `swift build` breaks the daemon on its next restart.
- **Run e2e checks against dockma's socket explicitly.** This machine also runs Lima, and an exported `DOCKER_HOST` overrides docker contexts. Use `DOCKER_HOST=unix://$HOME/.dockma/docker.sock`, as `scripts/e2e.sh` does, or Lima may be the one answering.
- **The daemon must run the main RunLoop, not `dispatchMain()`.** VZ objects and the `Daemon` are `@MainActor`. Under `dispatchMain()`, main-queue blocks run on a worker thread and Swift 6 isolation checks trap.
- **The daemon's exit code drives launchd.** `KeepAlive.SuccessfulExit=false` means:
  - Exit 0 is a requested stop or a startup failure, so there is no restart loop.
  - Non-zero is an unexpected guest poweroff or a VM error, and launchd restarts the daemon.
- **`launchctl bootout` returns before the daemon exits.** `LaunchAgent.bootout()` polls until the job is gone.
- **Guest consoles are TTYs.** Logs arrive with `\r\n` line endings, which Swift treats as a single Character, so split them with `isNewline`.
- **Kernel config gates in the Dockerfile.**
  - Every option in `vm/kernel/dockma.config` must survive `olddefconfig`. A dropped option means an unmet dependency.
  - `vm/kernel/check-docker-config.sh` enforces moby's required list. It exempts the iptables/xtables options because dockerd runs with `firewall-backend: nftables`, which needs the `nft` binary.
- **Stage-0 `/init` moves the initramfs into a tmpfs and runs `switch_root`.** runc can't `pivot_root` out of rootfs.
- **BuildKit forbids `mknod`.** Device nodes come from the kernel's `gen_init_cpio`.
- **Slow exit of `swift-package` (cause unconfirmed).** With Swift 6.4 on macOS 27.0.1, `swift-package` processes have stayed in the exiting (`E`) state for 30–60 minutes after `swift test` or a failed build. SIGKILL doesn't speed this up, but they do exit eventually. The work itself completes, so read results from the output instead of waiting for the process to exit.
  - Reproduced with the VM stopped and with a package outside the virtiofs-shared home.
  - Not ruled out: state left behind by using Virtualization.framework during that boot. No pre-VZ baseline was taken.
  - It doesn't happen every time; later `swift test` runs exited normally.

## Toolchain and conventions

- `swift-tools-version: 6.4`: Swift 6 language mode with strict concurrency. `platforms: [.macOS(.v14)]`.
- Every target enables the `ApproachableConcurrency` upcoming feature. Add it to any new target.
- Pure helpers on `@MainActor` types that tests call are marked `nonisolated`.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`) with `@testable import dockma`.
- Pinned guest versions are `ARG`s in `vm/Dockerfile`: kernel, Docker static bundle and moby's `check-config.sh` (each with sha256), Alpine, Go. Bumping `MOBY_VERSION` needs a new `CHECK_CONFIG_SHA256`.

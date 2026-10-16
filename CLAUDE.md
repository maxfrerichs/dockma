# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

dockma runs Docker on macOS inside a minimal Linux VM booted with Virtualization.framework. User-facing documentation lives in `README.md`: usage, configuration, the state directory and the architecture diagram. Keep the README in sync when you change CLI flags, defaults, files under `~/.dockma`, or pinned versions.

`Sources/DockmaCLI/DockmaCLI.docc/dockma.md` is generated from the ArgumentParser definitions. Regenerate it when commands, flags, abstracts or help text change: `swift package --allow-writing-to-package-directory generate-docc-reference`. The plugin rebuilds the release binary unsigned, and `make install` re-signs it.

The project has two halves:
- **Host (Swift).** The `dockma` CLI, plus a long-lived `dockma daemon` that a per-user launchd job (`io.dockma.daemon`) runs. The daemon owns the `VZVirtualMachine`.
- **Guest (`vm/`).** A custom 6.18 LTS kernel, a busybox initramfs, Docker's static binaries and `dockma-agent` (static Go).

## Host–guest protocol

The vsock ports are defined in `VMConfigurationBuilder.Port` and duplicated in `vm/agent/main.go`. Change both together.

| Port | Purpose |
|------|---------|
| 1024 | Byte proxy to `/var/run/docker.sock`. The host serves it as `~/.dockma/docker.sock`. |
| 1025 | JSON-lines control. **The host listens and the agent dials** (`VMHost.listen(onPort:accept:)`, installed before the VM starts). `AgentMessage` (Swift) mirrors `message` (Go). Guest→host: `hello`, `docker` (`ready`: whether dockerd's API answers), `ports`. Host→guest: `settime`, `shutdown`. |
| 1026 | TCP tunnel. The first line is `tcp <host:port>`; raw bytes follow. |
| 1027 | `dockma shell` sessions. Frames are `[type u8][len u32 BE][payload]`. The types are defined in `ShellFrame` (`Sources/DockmaCore/Shell/ShellProtocol.swift`) and mirrored in `vm/agent/shell.go`; change both together. Golden `resize` and `window` byte sequences are asserted in both test suites. The host serves this port as `~/.dockma/shell.sock`, and the daemon only proxies bytes. |

The host CLI talks to the daemon over `~/.dockma/control.sock`: one JSON line in (`ControlRequest`), one line out (`DaemonStatus`). `wait` is answered only once the agent reports Docker ready. If the daemon stops or exits first, the connection closes without a reply. `dockma start` waits on this, plus kqueue events for the socket appearing and the daemon exiting. The fallbacks that remain:
- Until it knows the daemon's pid, `start` asks `launchctl` again on each wake, or after 1 s without one.
- The agent retries a failed host dial after 1 s.
- While dockerd's socket is missing, the agent waits on inotify, with a 2 s fallback. It sleeps 1 s after other errors, or when the events stream ends.

The guest image carries a protocol number: `vm/agent/protocol`, installed as `~/.dockma/guest/guest-protocol`. It must equal `GuestImage.protocolVersion`, and a test asserts that. Bump both on any incompatible host↔guest change. `start` and the daemon refuse a mismatched guest with a rebuild hint.

The home directory is shared via virtiofs (tag `home`) and mounted in the guest **at the same host path**. The path is passed percent-encoded as `dockma.home=` on the kernel cmdline and decoded in `rcS`. Rosetta is the virtiofs tag `rosetta`, registered with binfmt_misc using flags `CF`.

## Source map

The core library lives in `Sources/DockmaCore/`, grouped by area. Rows from Daemon lifecycle to Support give paths relative to it.

| Area | Files |
|---|---|
| CLI commands | `Sources/DockmaCLI/Dockma.swift` — all subcommands, plus log tailing and following |
| Daemon lifecycle | `Daemon/Daemon.swift` — boot, signal handling, graceful stop, exit codes, time sync, log rotation |
| VM | `VM/VMConfigurationBuilder.swift` (devices, data disk, `GuestImage` protocol check), `VM/VMHost.swift` (VZ wrapper, vsock connect), `VM/KernelCmdline.swift`, `VM/Entitlements.swift` |
| Forwarding | `Forwarding/` — `SocketListener` (unix/TCP accept via dispatch source), `SocketCopier` (bidirectional copy with half-close), `VsockSocketProxy` (unix socket → agent vsock port; docker and shell), `PortForwarder` (reconciles the agent's port set into listeners) |
| Shell client | `Shell/ShellProtocol.swift` (frames, incremental decoder), `Shell/ShellSession.swift` (raw TTY, SIGWINCH, signal forwarding, stdin/output pumps) |
| Agent link | `Agent/AgentClient.swift` (accepts the agent's control connection, tracks Docker readiness), `Agent/AgentProtocol.swift` |
| launchd and CLI↔daemon | `Daemon/LaunchAgent.swift`, `Daemon/ControlProtocol.swift` (also `UnixSocket`, `DockerPing`) |
| Settings and paths | `Settings/Config.swift`, `Settings/Paths.swift` (also `DockmaError`) |
| Terminal output | `Terminal/TerminalStyle.swift` (color and ✓/✗ symbols, on a TTY without `NO_COLOR`; `Terminal.size()`), `Terminal/TerminalText.swift` (sanitize, truncate, `LogLineSplitter`), `Terminal/LogTail.swift` (appended bytes of a log across rotation; used by `logs -f` and the panel), `Terminal/LogPanel.swift` (fixed-height panel redrawn in place), `Terminal/LogPanelRenderer.swift` (draws the panel on a thread while `start`/`stop` block) |
| Support | `Support/Subprocess.swift` (runs launchctl and docker), `Support/KernelEvents.swift` (kqueue waits for a process exit or directory change), `Support/LineIO.swift`, `Support/Log.swift`, `Support/DockerContext.swift` |
| Guest build | `vm/Dockerfile`, `vm/kernel/dockma.config`, `vm/kernel/check-docker-config.sh` |
| Guest boot | `vm/rootfs/init` (stage 0), `etc/inittab`, `etc/init.d/{rcS,dockerd,shutdown}`, `usr/libexec/dockma-disk` (data disk: format only when blank; tested by `vm/tests/dockma-disk-test.sh` in the guest build), `etc/docker/daemon.json`, `etc/profile` (shell prompt; runs `usr/libexec/dockma-motd`, the whalesay-style greeting on interactive logins, tested by `vm/tests/dockma-motd-test.sh`), `usr/share/udhcpc/default.script`, `etc/e2fsck.conf` (`broken_system_clock`, because the agent steps the clock after boot), `usr/lib/os-release` (`PRETTY_NAME="dockma VM"`, which `scripts/e2e.sh` checks in `docker info` to identify dockma's engine) |
| Guest agent | `vm/agent/main.go` (servers, control dialer, port watcher and Docker readiness), `filewaiter.go` (inotify wait for dockerd's socket), `ports.go` (pure port extraction), `shell.go` (shell sessions on a pty via creack/pty or on pipes) |

## Commands

```sh
make build                # swift build + ad-hoc codesign with dockma.entitlements (required to run the VM)
make install              # signed release binary → ~/.local/bin/dockma (PREFIX=...)
make guest                # build vm/out/{Image,initramfs.cpio.lz4} with any arm64 docker (buildx)
make install-guest        # copy guest artifacts to ~/.dockma/guest/
make test                 # swift test (Swift Testing)
make e2e                  # build + scripts/e2e.sh against a real VM (starts/restarts/stops the user's VM)
scripts/bench.sh          # boot time with a phase breakdown, plus network throughput (restarts the user's VM RUNS times; RUNS=0 for network only)
swift test --filter DockmaCoreTests.planIsEmptyWhenNothingChanged   # one test
```

Agent tests run inside `make guest`, in the Dockerfile's `go vet` and `go test` step. To run them alone:

```sh
tar cf - -C vm agent | docker run --rm -i golang:1.27-alpine sh -c 'tar xf - && cd agent && go test ./...'
```

To run the daemon in the foreground, stop the launchd job first (`dockma stop`), then run `.build/debug/dockma daemon` (built by `make build`, so it is signed) and stop it with Ctrl-C.

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
- **`launchctl bootout` returns before the daemon exits.** `LaunchAgent.bootout()` waits for the daemon's pid to exit (kqueue). launchd then removes the job without any event, so a short `launchctl` check loop remains after the exit.
- **The stop deadline counts from `requestStop()`.**
  - The VM is hard-stopped after `Daemon.shutdownGrace` (20 s) if the agent got `shutdown`, and after 2 s if no agent was connected.
  - An agent that connects during a stop still gets `shutdown`, but its deadline is the request time plus the grace. A reconnecting agent can't postpone the hard stop.
  - `bootout`'s timeout (40 s) must stay above `shutdownGrace`, or `dockma stop` gives up before the daemon exits.
- **Guest consoles are TTYs.** Logs arrive with `\r\n` line endings, which Swift treats as a single Character, so split them with `isNewline`.
- **Kernel config gates in the Dockerfile.**
  - Every option in `vm/kernel/dockma.config` must survive `olddefconfig`. A dropped option means an unmet dependency. Every `# CONFIG_X is not set` line must stay disabled; another option's `select` can turn it back on.
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
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`) with `@testable import DockmaCore`.
- Pinned guest versions are `ARG`s in `vm/Dockerfile`: kernel, Docker static bundle and moby's `check-config.sh` (each with sha256), Alpine, Go. Bumping `MOBY_VERSION` needs a new `CHECK_CONFIG_SHA256`.

## Swift naming

Swift code follows the [API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/). The Go agent follows Go conventions instead. These guideline rules are the ones that come up here:

- **Case and acronyms.** Types and protocols are UpperCamelCase; everything else is lowerCamelCase. Acronyms take one case throughout: `macAddress`, `randomMACAddress()`, `lockFD`, `parsePID`, `stdinEOF`.
- **Booleans read as assertions**: `isRunning`, `isConnected`, `hasVirtualization()`. Not `loaded` or `agentConnected`.
- **Grammar follows side effects.**
  - Without side effects, a name is a noun phrase: `terminalSize()`, `bindAddresses(for:)`.
  - With side effects, it is an imperative verb phrase: `createDirectories()`, `requestStop()`, `cleanUp()`.
  - Properties and types are nouns, never verbs.
- **Factory methods start with `make`.**
- **Argument labels.**
  - Omit a label only when the arguments can't be told apart (`SocketCopier.pipe(a, b)`) or the call is a value-preserving conversion (`IPAddress("::1")`).
  - A first argument that forms a prepositional phrase gets a label starting at the preposition: `load(from:)`, `save(to:)`, `takeCredit(upTo:)`.
  - Label every other argument, defaulted ones included.
- **Abbreviations.** Only searchable terms of art: `fd`, `argv`, `tty`, `pid`, `initrd`. Don't reuse a standard-library name for something else (e.g. a nested `Result`).
- **Prefer methods and static members to free functions**, unless there is no obvious `self`.
- **Doc comments.** Every new or changed declaration gets a `///` summary: a single sentence fragment saying what it does, returns, creates or is. A computed property that isn't O(1) says so. Existing undocumented code gets a summary when it is next touched; there is no backfill.

Project rules, which the guidelines don't cover:

- **Names that leave the process are frozen.** Renaming one of these silently changes a format that other binaries or users depend on:
  - **Codable property names** are JSON keys.
    - `ShellStart` and `AgentMessage` are mirrored by Go JSON tags in `vm/agent`.
    - `ControlRequest` and `DaemonStatus` are exchanged with a daemon that may be an older binary.
    - `Config` is stored in `~/.dockma/config.json`.
  - **String raw values of Codable enums** are wire strings (`ControlRequest.Command`, `DaemonStatus.State`). So are the `AgentMessage.type` values.
  - **ArgumentParser property names** become flag names (`ConfigCommand.portBindAddress` is `--port-bind-address`). `name:` isn't pinned anywhere.

  To rename one of these, keep the old external name explicitly with `CodingKeys`, a raw value or `@Option(name:)`, and add a test that decodes the old form. The rest of DockmaCore is `public` only for `DockmaCLI` and the tests, so other renames are free.
- **Units.** Put the unit in the name when the type doesn't carry it: `memoryMiB`, `diskGiB`, `timeoutSeconds`. Prefer `Duration` for new time values.
- **Static factories in enum-case style are fine**, e.g. `SocketListener.unix(path:handler:)` and `AgentMessage.shutdown`.
- **Modules.** The modules are `DockmaCore` and `DockmaCLI`; the product is `dockma`. No module may be named `Dockma`, because the CLI's `@main struct Dockma` would shadow it.
- **CLI command types** are named after the command. They get a `Command` suffix only when the name clashes with a DockmaCore type: `ShellCommand`, `ConfigCommand`, `DaemonCommand`.
- **Source folders** under `Sources/DockmaCore/` are UpperCamelCase feature areas. A new file goes in its area's folder, and the source map above is updated with it.

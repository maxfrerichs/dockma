# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

dockma runs Docker on macOS inside a minimal Linux VM booted with Virtualization.framework. User-facing documentation lives in `README.md`: usage, configuration, the state directory and the architecture diagram. Keep the README in sync when you change CLI flags, defaults, files under `~/.dockma`, or pinned versions.

`CHANGELOG.md` records every user-visible change: features, fixes, changed defaults, and anything that needs a guest rebuild or breaks compatibility (a `GuestImage.protocolVersion` bump always does). Add entries under `## Unreleased` in the same change that makes them. A release moves those entries under a new `## <version> – <date>` heading, sets `DockmaVersion.current` (`Support/Version.swift`, printed by `dockma --version`) to that version, and gets an annotated git tag of the same name, without a `v` prefix (`0.1.0`). A test checks the constant against the newest heading, and the release build checks the binary's `--version` against the tag. Pushing the tag runs `.github/workflows/release.yml`, which drafts a GitHub release with that section as its notes (extracted by `scripts/release-notes.py`, which needs the en dash) and fails without one; publish the draft by hand. Before 1.0, a new feature or an incompatible host↔guest change bumps the minor version; fixes bump the patch.

`Sources/DockmaCLI/DockmaCLI.docc/dockma.md` is generated from the ArgumentParser definitions. Regenerate it when commands, flags, abstracts or help text change: `swift package --allow-writing-to-package-directory generate-docc-reference`. The plugin rebuilds the release binary unsigned, and `make install` re-signs it.

The project has two halves:
- **Host (Swift).** The `dockma` CLI, plus a long-lived `dockma daemon` that a per-user launchd job runs: `io.dockma.daemon` for `~/.dockma`, `io.dockma.daemon.<8 hex of SHA-256 of the state path>` for any other `DOCKMA_HOME` (`LaunchAgent.label(for:)`). The default label is a frozen name. The daemon owns the `VZVirtualMachine`.
- **Guest (`vm/`).** A custom 6.18 LTS kernel, a busybox initramfs, Docker's static binaries and `dockma-agent` (static Go).

## Host–guest protocol

The vsock ports are defined in `VMConfigurationBuilder.Port` and duplicated in `vm/agent/main.go`. Change both together.

| Port | Purpose |
|------|---------|
| 1024 | Byte proxy to `/var/run/docker.sock`. The host serves it as `~/.dockma/docker.sock`. |
| 1025 | JSON-lines control. **The host listens and the agent dials** (`VMHost.listen(onPort:accept:)`, installed before the VM starts). `AgentMessage` (Swift) mirrors `message` (Go). Guest→host: `hello`, `docker` (`ready`: whether dockerd's API answers), `ports`. Host→guest: `settime`, `shutdown`. |
| 1026 | TCP and UDP tunnels. The first line is `tcp <host:port>` or `udp <host:port>`. For TCP, raw bytes follow. For UDP, one connection carries one client's flow as `[len u16 BE][payload]` frames both ways: `DatagramFrame` (Swift) mirrors `writeDatagram`/`readDatagram` in `vm/agent/udp.go`, and both test suites assert the same golden bytes. The host expires an idle flow after 90 s (docker-proxy's UDP timeout, checked every 5 s) by closing the connection; the agent's 180 s deadline is only a backstop. |
| 1027 | `dockma shell` sessions. Frames are `[type u8][len u32 BE][payload]`. The types are defined in `ShellFrame` (`Sources/DockmaCore/Shell/ShellProtocol.swift`) and mirrored in `vm/agent/shell.go`; change both together. Golden `resize` and `window` byte sequences are asserted in both test suites. The host serves this port as `~/.dockma/shell.sock`, and the daemon only proxies bytes. The protocol is specified in `docs/shell-protocol.md`; update it with any change to frames or session rules. |

The host CLI talks to the daemon over `~/.dockma/control.sock`: one JSON line in (`ControlRequest`), one line out (`DaemonStatus`). `wait` is answered only once the agent reports Docker ready. If the daemon stops or exits first, the connection closes without a reply. `dockma start` waits on this, plus kqueue events for the socket appearing and the daemon exiting. The fallbacks that remain:
- Until it knows the daemon's pid, `start` asks `launchctl` again on each wake, or after 1 s without one.
- The agent retries a failed host dial after 1 s.
- While dockerd's socket is missing, the agent waits on inotify, with a 2 s fallback. It sleeps 1 s after other errors, or when the events stream ends.

The guest image carries a protocol number: `vm/agent/protocol`, installed as `~/.dockma/guest/guest-protocol`. It must equal `GuestImage.protocolVersion`, and a test asserts that. Bump both on any incompatible host↔guest change. `start` and the daemon refuse a mismatched guest with a rebuild hint.

The agent accepts vsock connections only from the host (CID 2, `isHostPeer`), and the kernel has `VSOCKETS_LOOPBACK` off, so containers can't reach these ports. The host's port 1025 can't tell the agent from another process in the guest (same CID); the README documents that.

The home directory is shared via virtiofs (tag `home`) and mounted in the guest **at the same host path**. The path is passed percent-encoded as `dockma.home=` on the kernel cmdline and decoded in `rcS`, like `dockma.state=` (the state directory, where the guest reads the user's `daemon.json`, `ca-certificates/` and `certs.d/`; only visible when it lies under home). The cmdline also carries `panic=5`, so a panicked guest reboots. VZ reboots a Linux guest in place (no `guestDidStop`, same daemon pid); the agent reconnects. An open `dockma shell` session does not end when that happens: its connection stays open until the client next writes (see `docs/shell-protocol.md`). Rosetta is the virtiofs tag `rosetta`, registered with binfmt_misc using flags `CF`.

## Source map

The core library lives in `Sources/DockmaCore/`, grouped by area. Rows from Daemon lifecycle to Support give paths relative to it.

| Area | Files |
|---|---|
| CLI commands | `Sources/DockmaCLI/Dockma.swift` — all subcommands, plus log tailing and following |
| Daemon lifecycle | `Daemon/Daemon.swift` — boot, signal handling, graceful stop, exit codes, time sync, log rotation |
| VM | `VM/VMConfigurationBuilder.swift` (devices, data disk, `GuestImage` protocol check), `VM/GuestRelease.swift` (`dockma install`: curl the release's `dockma-linux-<version>-arm64.tar.gz` and `SHA256SUMS`, verify, check the protocol, swap into `guest/` with `RENAME_SWAP`; an flock on `.guest-install.lock` serializes installs and lets one clear the staging dirs of killed ones), `VM/VMHost.swift` (VZ wrapper, vsock connect), `VM/KernelCmdline.swift`, `VM/Entitlements.swift` |
| Forwarding | `Forwarding/` — `SocketListener` (unix/TCP accept via dispatch source; optional loopback-only peer filter), `SocketCopier` (bidirectional copy with half-close), `VsockSocketProxy` (unix socket → agent vsock port; docker and shell), `DatagramRelay` (a host UDP socket; one vsock flow per client, queued while the tunnel connects, idle expiry, a flow cap that evicts the least recently active flow, and a relay-wide byte budget for queued frames), `PortForwarder` (reconciles the agent's port set, keyed by port and transport, into listeners and relays; loopback ports below 1024 bind the wildcard and admit only loopback peers, because macOS refuses the non-root loopback bind for TCP and UDP alike) |
| Shell client | `Shell/ShellProtocol.swift` (frames, incremental decoder), `Shell/ShellSession.swift` (raw TTY, SIGWINCH, signal forwarding, stdin/output pumps) |
| Agent link | `Agent/AgentClient.swift` (accepts the agent's control connection, tracks Docker readiness), `Agent/AgentProtocol.swift` |
| launchd and CLI↔daemon | `Daemon/LaunchAgent.swift`, `Daemon/ControlProtocol.swift` (also `UnixSocket`, `DockerPing`) |
| Settings and paths | `Settings/Config.swift`, `Settings/Paths.swift` (also `DockmaError`) |
| Terminal output | `Terminal/TerminalStyle.swift` (color and ✓/✗ symbols, on a TTY without `NO_COLOR`; `Terminal.size()`, and `Terminal.rendersEscapes`, which gates color and the panel on `TERM` not being `dumb`), `Terminal/TerminalText.swift` (sanitize, truncate, `LogLineSplitter`), `Terminal/LogTail.swift` (appended bytes of a log across rotation; used by `logs -f` and the panel), `Terminal/LogPanel.swift` (fixed-height panel redrawn in place), `Terminal/LogPanelRenderer.swift` (draws the panel on a thread while `start`/`stop` block) |
| Support | `Support/Subprocess.swift` (runs launchctl, docker, curl and tar), `Support/KernelEvents.swift` (kqueue waits for a process exit or directory change), `Support/LineIO.swift`, `Support/Log.swift`, `Support/DockerContext.swift`, `Support/Version.swift` (`DockmaVersion`) |
| Guest build | `vm/Dockerfile`, `vm/kernel/dockma.config`, `vm/kernel/check-docker-config.sh` |
| Guest boot | `vm/rootfs/init` (stage 0), `etc/inittab`, `etc/init.d/{rcS,dockerd,shutdown}`, `usr/libexec/dockma-disk` (data disk: format only when blank; tested by `vm/tests/dockma-disk-test.sh` in the guest build), `etc/docker/daemon.json`, `etc/profile` (shell prompt; runs `usr/libexec/dockma-motd`, the whalesay-style greeting on interactive logins, tested by `vm/tests/dockma-motd-test.sh`), `usr/share/udhcpc/default.script` (replaces the address only when it changed; writes `/run/dockma/gateway` and `upstream-dns`, points `resolv.conf` at the VM's own address and installs the `dockma_dns` nft table that redirects its port 53 to the agent's 10053), `etc/init.d/dockerd` (ulimit, generated config validated with `dockerd --validate`, baked config as fallback), `etc/e2fsck.conf` (`broken_system_clock`, because the agent steps the clock after boot), `usr/lib/os-release` (`PRETTY_NAME="dockma VM"`, which `scripts/e2e.sh` checks in `docker info` to identify dockma's engine) |
| Guest agent | `vm/agent/main.go` (servers, host-only peer check, control dialer, port watcher and Docker readiness, hourly `fstrim`), `filewaiter.go` (inotify wait for dockerd's socket), `ports.go` (pure port extraction), `udp.go` (UDP flow relay and datagram framing), `shell.go` (shell sessions on a pty via creack/pty or on pipes), `dns.go` (DNS on `0.0.0.0:10053`, reached through the nftables redirect of `<eth0 ip>:53` that the udhcpc hook installs, so port 53 stays free for containers: answers `host.docker.internal`/`gateway.docker.internal` with the lease's router, relays the rest to the lease's DNS servers, refuses other hosts on the eth0 subnet), `daemonconfig.go` (`dockma-agent daemon-config`: baked `daemon.json` + the user's + defaults for `log-opts` and `host-gateway-ips`; protected keys stay baked) |
| Installer | `install.sh` (POSIX sh, run as `curl -fsSL <site>/install.sh \| sh`): picks the highest X.Y.Z release from the GitHub API, because `releases/latest` skips prereleases. It checks `SHA256SUMS` and, when a logged-in `gh` is available, the attestation; checks `--version` against the tag; refuses versions before 0.3.0 (no `dockma install`); runs the downloaded binary's `dockma install` first, so a failed guest download changes nothing; then moves the binary into `~/.local/bin` as a new inode. Test it with `DOCKMA_INSTALL_DIR=<scratch>` plus `DOCKMA_HOME=<scratch>` (or `DOCKMA_SKIP_GUEST=1`) so `~/.local/bin` and `~/.dockma` stay untouched, and against a local `DOCKMA_RELEASE_URL` for the failure paths. |
| CI and releases | `.github/workflows/lint.yml` (actionlint and shellcheck at warning level, both as digest-pinned images; busybox-only constructs carry `# shellcheck disable=` with a reason), `.github/workflows/cli.yml` (`make test`, the signed release binary and a docc freshness check on the `xcode-27` runner, Xcode 27.1 pinned via `DEVELOPER_DIR`), `guest.yml` (`make guest` on `ubuntu-24.04-arm`, gha BuildKit cache via `BUILDX_FLAGS`; packs `dockma-linux-<version>-arm64.tar.gz`, which `GuestRelease.assetName` must match), `release.yml` (on a version tag, or by hand for an older tag: calls both uncached, then `SHA256SUMS`, provenance attestations and a draft release). Actions are pinned by commit SHA. `.github/actionlint.yaml` declares the `xcode-27` label. Hosted macOS runners have no nested virtualization, so `make e2e` stays local. |
| Website | `site/` (Hugo: layouts, `data/*.yaml`, `assets/`, fonts), `scripts/site-prepare.py` (generates `site/data/facts.json` from the `vm/Dockerfile` ARGs and `site/content/reference/*.md` from the committed docc file, and copies `install.sh` to `site/static/`), `.github/workflows/pages.yml` (pinned Hugo, deploys to Pages). SEO lives in `layouts/baseof.html` (canonical, Open Graph, JSON-LD), `layouts/robots.txt` and the built-in sitemap; `static/og.png` is the 1200×630 share image and `static/favicon.svg` the icon (both deliberately avoid the Docker logo). `make site` builds it, `make site-serve` previews it. The reference is only as fresh as the docc file, so regenerate that first. The boot time is `params.bootSeconds` in `site/hugo.toml`, updated by hand from `scripts/bench.sh`. |

## Commands

```sh
make build                # swift build + ad-hoc codesign with dockma.entitlements (required to run the VM)
make install              # signed release binary → ~/.local/bin/dockma (PREFIX=...)
make guest                # build vm/out/{dockma-kernel,dockma-initrd.img} with any arm64 docker (buildx)
make install-guest        # copy guest artifacts to ~/.dockma/guest/
dockma install            # or download the released guest of DockmaVersion.current (DOCKMA_RELEASE_URL overrides the source)
make test                 # swift test (Swift Testing)
make e2e                  # build + scripts/e2e.sh against its own VM in ~/.dockma-e2e (E2E_HOME); the user's VM keeps running
scripts/bench.sh          # boot time with a phase breakdown, plus network throughput (restarts the user's VM RUNS times; RUNS=0 skips boot, NETWORK=0 skips network)
DISK=1 RUNS=0 NETWORK=0 scripts/bench.sh                                  # disk: fio and per-step build overhead on LAYER_BASE (steps parsed by scripts/bench-build-steps.py)
ENGINE_SOCKET=$HOME/.lima/default/sock/docker.sock DISK=1 scripts/bench.sh   # same network/disk phases against another engine, as a baseline
swift test --filter DockmaCoreTests.planIsEmptyWhenNothingChanged   # one test
```

Agent tests run inside `make guest`, in the Dockerfile's `go vet` and `go test` step. To run them alone:

```sh
tar cf - -C vm agent | docker run --rm -i golang:1.27-alpine sh -c 'tar xf - && cd agent && go test ./...'
```

To run the daemon in the foreground, stop the launchd job first (`dockma stop`), then run `.build/debug/dockma daemon` (built by `make build`, so it is signed) and stop it with Ctrl-C.

Changes under `vm/` only take effect after `make guest install-guest` followed by `dockma restart`. Changes to the Swift daemon need `make build` and a restart.

To iterate on `vm/kernel/dockma.config` without a full `make guest`, build only the source stage and rerun the config steps. Review every option the diff newly enables, including ones pulled in by `select` or `default`:

```sh
docker buildx build --platform linux/arm64 --target kernel-src --load -t dockma-kernel-src vm
docker run --rm -i dockma-kernel-src sh -c 'cd /build/linux && cat >/build/dockma.config && make ARCH=arm64 tinyconfig >/dev/null && scripts/kconfig/merge_config.sh -m .config /build/dockma.config >/dev/null && make ARCH=arm64 olddefconfig >/dev/null && cat .config' <vm/kernel/dockma.config >new.config
diff <(grep ^CONFIG_ vm/out/kernel.config | sort) <(grep ^CONFIG_ new.config | sort)
```

No linter or formatter is configured for the code. Lint workflows with `docker run --rm -v "$PWD:/repo:ro" -w /repo rhysd/actionlint`.

## Gotchas

- **`swift build` and `swift test` strip the entitlement.** Both relink the binary unsigned (`make test` re-signs it afterwards). Without `com.apple.security.virtualization` the daemon can't start a VM, and `dockma start` refuses to run. Always use `make build` or `make install`.
- **launchd runs the binary you started it with.** The plist's `ProgramArguments` is the absolute path of the binary that ran `dockma start`. A later unsigned `swift build` breaks the daemon on its next restart.
- **Run e2e checks against dockma's socket explicitly.** This machine also runs Lima, and an exported `DOCKER_HOST` overrides docker contexts. Use `DOCKER_HOST=unix://$HOME/.dockma/docker.sock`, as `scripts/e2e.sh` does, or Lima may be the one answering. Against a separate VM (`DOCKMA_HOME=~/.dockma-e2e`), export `DOCKMA_HOME` for every `dockma` command too, `dockma shell` included; without it they reach the user's VM.
- **Only the home directory is shared with the VM.** `docker run -v` with a host path outside it (`/tmp`, `/private/tmp`) mounts an empty directory without an error. Pass files in with `tar c … | docker run -i … tar x`.
- **Code that blocks on the cooperative pool must not wait for `DispatchQueue.global()`.** That queue shares its per-CPU thread budget with the Swift cooperative pool. On the 3-CPU CI runner, three sync tests blocked in `Subprocess.run` waited on a `global()` block that never got a thread, and the whole test process froze. Use a private serial queue (it always gets a thread) or a dedicated `Thread`; async tests run blocking calls through `runOnThread` (`Tests/DockmaCoreTests/BlockingWork.swift`). To find a hang like this, `cli.yml` samples the test process after 5 minutes.
- **The daemon must run the main RunLoop, not `dispatchMain()`.** VZ objects and the `Daemon` are `@MainActor`. Under `dispatchMain()`, main-queue blocks run on a worker thread and Swift 6 isolation checks trap.
- **The daemon's exit code drives launchd.** `KeepAlive.SuccessfulExit=false` means:
  - Exit 0 is a requested stop or a startup failure, so there is no restart loop.
  - Non-zero is an unexpected guest poweroff or a VM error, and launchd restarts the daemon.
- **`launchctl bootout` returns before the daemon exits.** `LaunchAgent.bootout()` waits for the daemon's pid to exit (kqueue). launchd then removes the job without any event, so a short `launchctl` check loop remains after the exit.
- **The stop deadline counts from `requestStop()`.**
  - The VM is hard-stopped after `Daemon.shutdownGrace` (25 s) if the agent got `shutdown`, and after 2 s if no agent was connected.
  - Keep the deadlines ordered: dockerd's own shutdown (max of `shutdown-timeout` and each container's stop timeout + 5 s: 15 s by default) < the guest `shutdown` script's wait (20 s) < `shutdownGrace` (25 s) < the plist's `ExitTimeOut` (30 s) < `bootout` (40 s).
  - An agent that connects during a stop still gets `shutdown`, but its deadline is the request time plus the grace. A reconnecting agent can't postpone the hard stop.
  - `bootout`'s timeout (40 s) must stay above `shutdownGrace`, or `dockma stop` gives up before the daemon exits.
- **Guest logs leave through one virtio console device with named ports** (`VMConfigurationBuilder.makeLogPort`). "console" is the kernel console, `hvc0`, a TTY, so `console.log` lines end in `\r\n`, which Swift treats as one Character: split with `isNewline`. "docker" is a plain port that rcS links as `/dev/virtio-ports/docker`; dockerd writes there directly, with `\n` endings. The guest finds ports by name, not probe order, so `driver_async_probe=virtio-pci` (about 10 ms) would now be safe; it isn't enabled.
- **The driver adds multiport ports asynchronously.** `hvc0` appeared only about 2 ms before `/init` ran, so stage-0 `/init` waits up to 1 s for `/dev/console` and reopens its fds, but only if it opens: a failed redirection on `exec` or on a special builtin like `:` ends the shell, and PID 1 exiting panics the kernel. Probe with `true`.
- **Kernel config gates in the Dockerfile.**
  - Every option in `vm/kernel/dockma.config` must survive `olddefconfig`. A dropped option means an unmet dependency. Every `# CONFIG_X is not set` line must stay disabled; another option's `select` can turn it back on.
  - `vm/kernel/check-docker-config.sh` enforces moby's required list. It exempts the iptables/xtables options because dockerd runs with `firewall-backend: nftables`, which needs the `nft` binary.
  - Without modules, a missing option shows up only when a container asks for it. `scripts/e2e.sh` probes the ones kube-proxy, k3s and CNIs use. Check a new option with `/proc/config.gz` in the guest.
  - An enabled option doesn't prove the feature works: verify it with the workload or the e2e probe. iptables-nft translates some targets into native nftables expressions, so `-j NFLOG` needs `NFT_LOG`, not only `NETFILTER_XT_TARGET_NFLOG`.
  - `IP_NF_IPTABLES` and `IP6_NF_IPTABLES` are not the legacy tables (those are `IP*_NF_IPTABLES_LEGACY`, kept off). They register each family's xt extensions for iptables-nft: without `IP6_NF_IPTABLES`, ip6tables has no `MARK` target or `addrtype` match, even with `NETFILTER_XT_MARK=y`.
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

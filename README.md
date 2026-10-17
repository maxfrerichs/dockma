# dockma

Lightweight tool for running Docker on macOS.

## tl;dr

dockma boots a minimal Linux VM with Apple's Virtualization.framework and runs the Docker Engine inside it. The macOS `docker` CLI talks to it through a Unix socket, and a launchd job keeps it running in the background. Your home directory is shared into the VM.

## Features

- **Minimal guest OS.**
  - Kernel: a custom 6.18 LTS kernel built from `tinyconfig` plus only the drivers and features Docker needs. Everything is built in, with no modules. It is compiled with `-O2` and the regular SLUB allocator, not tinyconfig's size-first `-Os` and `SLUB_TINY`.
  - Userspace: a busybox initramfs containing Docker's static binaries and a small guest agent.
  - Boots in around 1.1s
- **Shared `$HOME` directory.**
  - `$HOME` is mounted inside the VM at the identical path (for example `/Users/you`) via virtiofs.
  - So `docker run -v "$PWD:/src"` works from anywhere under your home directory.
- **Published ports on localhost.**
  - `docker run -p 8080:80 …` is reachable at `localhost:8080` (IPv4 and IPv6), with no manual forwarding. UDP works the same way: `-p 1053:53/udp` answers on `localhost:1053`.
  - Each UDP client gets its own tunnel and source port in the VM. It ends about 90 s after its last packet in either direction, matching docker-proxy.
  - The listener goes away when the container stops.
  - Ports below 1024, such as DDEV's router on 80 and 443, work too. macOS lets a non-root process bind them only on the wildcard address, so with the default `127.0.0.1` the daemon listens on `0.0.0.0` and `::` and closes any connection that isn't from a loopback address. UDP ports do the same and drop datagrams from non-loopback senders.
    - Other machines can't use the port, but a port scan from the network sees a TCP port as open, because the TCP handshake completes before the close. A UDP port looks `open|filtered`.
    - Anything else listening on `*:80` conflicts with it.
    - A process running as root that holds `127.0.0.1:80` itself takes precedence: dockma's listener starts without error but receives none of that traffic.
    - The daemon logs the first connection it closes, or datagram it drops, on each listener, so `dockma logs --daemon` shows why a remote client got no answer.
    - macOS may ask whether `dockma` may accept incoming connections. The listener stays loopback-only whatever you answer.
- **Run amd64 images via Rosetta.**
  - `docker run --platform linux/amd64 …` runs x86-64 images through Rosetta for Linux.
- **Runs in the background.**
  - A per-user launchd job keeps the VM running after the CLI exits.
  - It restarts the VM if the guest crashes.
- **A shell in the VM.**
  - `dockma shell` opens a root shell inside the VM; `dockma shell -- <cmd>` runs a single command there.
  - It goes through the guest agent rather than Docker, so it still works when dockerd is broken.
- **Graceful shutdown.**
  - `dockma stop` asks the guest to stop dockerd and power off cleanly.
  - Your images, containers and volumes persist on a sparse disk image.

> **Status:** early and experimental. It has only been tested on Apple Silicon with macOS 27. Expect rough edges; see [Limitations](#limitations). It is designed and optimized for Apple Silicon.

## Requirements

- An Apple Silicon Mac (arm64).
- macOS 14 or later. The package targets macOS 14, but only macOS 27 has been tested.
- Xcode with Swift 6.4, for building the CLI.
- The `docker` CLI on macOS, e.g. `brew install docker`. dockma provides the engine, not the client.
- **To build the guest image:** any arm64 Docker engine with buildx, such as Lima, Colima or Docker Desktop. Once dockma runs, it can rebuild its own guest. The build downloads from:
  - kernel.org
  - download.docker.com
  - GitHub
  - Docker Hub (Alpine and Go images)
  - the Go module proxy
- **Optional:** Rosetta, for amd64 images. Install it with `softwareupdate --install-rosetta`.

## Quick start

### From a release

Each [release](../../releases) has three files:
- `dockma-<version>-macos-arm64.tar.gz`: the signed `dockma` binary;
- `dockma-guest-<version>.tar.gz`: the guest kernel, initramfs and `guest-protocol`, built for that version's protocol;
- `SHA256SUMS`.

The CLI and the guest come from the same tag; use both from one release. With the three files in the current directory:

```sh
shasum -a 256 -c SHA256SUMS
# Only for files downloaded with a browser: macOS kills a quarantined,
# unnotarized binary at launch.
xattr -d com.apple.quarantine dockma-*.tar.gz

mkdir -p ~/.local/bin ~/.dockma/guest
tar -xzf dockma-*-macos-arm64.tar.gz -C ~/.local/bin dockma
tar -xzf dockma-guest-*.tar.gz -C ~/.dockma/guest

dockma start
docker context use dockma
```

The binary is ad-hoc signed, not notarized. `curl` doesn't quarantine what it downloads, so the `xattr` step isn't needed then. `gh attestation verify <file> --repo <owner>/dockma` checks that a tarball was built by this repository's release workflow.

### From source

```sh
# 1. Build the guest kernel and initramfs (needs an existing arm64 Docker engine)
make guest
make install-guest            # copies vm/out/* to ~/.dockma/guest/

# 2. Build, sign and install the CLI to ~/.local/bin/dockma
make install

# 3. Start the VM
dockma start

# 4. Point the docker CLI at dockma
docker context use dockma     # created by `dockma start`
# or: export DOCKER_HOST=unix://$HOME/.dockma/docker.sock

docker run --rm hello-world
```

If `DOCKER_HOST` is already set, it takes precedence over docker contexts. This happens with Lima, for example. Either unset it or point it at `unix://$HOME/.dockma/docker.sock`. `dockma start` and `dockma status` warn when `DOCKER_HOST` points elsewhere.

> **Always build with `make build` or `make install`, never plain `swift build`.**
> - Running VMs requires the `com.apple.security.virtualization` entitlement.
> - `swift build` produces an unsigned binary without it.
> - `dockma start` refuses to run without the entitlement.

## Usage

```
dockma start [--timeout <s>]      Start the VM in the background and wait until Docker answers
dockma stop                       Shut the VM down gracefully
dockma restart [--timeout <s>]    Stop, then start
dockma status [--json]            State, uptime, resources, guest kernel, forwarded ports
dockma shell [-t|-T] [-- cmd …]   Root shell in the VM, or run a command there
dockma logs [-n N] [-f]           Kernel and boot log of the VM
dockma logs --docker [-n N] [-f]  dockerd's log
dockma logs --daemon [-n N] [-f]  Log of the host-side daemon (VM lifecycle, port forwards)
dockma config [options]           Show or change settings (applied on next start)
dockma delete [-f]                Delete the data disk (all images, containers, volumes), config and logs
dockma --version                  Print the version
```

Example:

```console
$ dockma status
state:    running
docker:   ready (/Users/you/.dockma/docker.sock)
uptime:   12m 4s
vm:       6 CPUs, 4096 MiB, kernel 6.18.57
agent:    connected 0.5.0
ports:    8080, 1053/udp
daemon:   pid 55658
```

### Shell

```console
$ dockma shell                     # interactive login shell (root, in /root)
dockma:~# cat /proc/meminfo | head -3
dockma:~# exit

$ dockma shell -- uname -r          # run one command; stdout, stderr and exit code pass through
6.18.57
$ dockma shell -- sh -c 'ls /var/lib/docker' | wc -l
$ echo data | dockma shell -- cat   # stdin is forwarded
```

The interactive shell greets you with the Docker whale saying a random quip, whalesay style, followed by a status line: kernel, uptime and data disk usage. `dockma shell -- cmd` prints only the command's output. To list every quip, run `dockma shell -- /usr/libexec/dockma-motd --all`.

TTY handling follows ssh:
- `dockma shell` gets a pseudo-terminal when stdin is a terminal. Window resizes are forwarded, and Ctrl-C reaches remote programs.
- `dockma shell -- cmd` uses plain pipes. stdout and stderr stay separate, and Ctrl-C is forwarded to the command as SIGINT.
- `-t` forces a pseudo-terminal, and `-T` disables it.
- A missing command exits with 127.
- If the client goes away, the remote process gets SIGHUP, then SIGKILL after 2 s.
- There is no escape sequence like ssh's `~.`. If the agent stops responding, kill the `dockma shell` process from another terminal.

Use it to inspect the VM, for example `ps`, `mount`, `nft list ruleset` and `cat /proc/pressure/memory`. `docker` itself isn't installed in the VM. Use `docker exec` from macOS to get into a container.

### Configuration

`dockma config` with no options prints the current settings. Changes take effect on the next `dockma restart`.

| Option | Default | Description |
|---|---|---|
| `--cpus <n>` | half the host's cores (min. 2) | Virtual CPUs |
| `--memory <MiB>` | `4096` | Guest memory |
| `--disk <GiB>` | `64` | Size of the sparse data disk. It can only grow; the guest grows the filesystem on boot. |
| `--port-bind-address <ip>` | `127.0.0.1` | Host address that published ports bind to. With `127.0.0.1` they're also bound on `::1`; with `0.0.0.0`, also on `::`. Use `0.0.0.0` to expose them to your network. With a loopback address, ports below 1024 bind the wildcard and accept only loopback peers. |
| `--rosetta <bool>` | `true` | Attach Rosetta for amd64 images |
| `--autostart <bool>` | `false` | Start dockma at login. This installs the launchd plist into `~/Library/LaunchAgents`. |

Settings are stored in `~/.dockma/config.json`. The VM's MAC address is generated once and stored there, so the VM keeps the same NAT IP across restarts.

### Files

Everything lives under `~/.dockma`. You can override the location with `DOCKMA_HOME`, but socket paths must stay under 104 bytes.

The directory and `logs/` are kept at mode 0700, and `data.img`, `config.json` and the VM logs at 0600: the data disk holds everything containers store, and other local accounts can often traverse a macOS home directory. dockma resets these modes on every start.

| Path | Contents |
|---|---|
| `docker.sock` | Docker API socket for the macOS `docker` CLI |
| `control.sock` | CLI ↔ daemon control socket |
| `shell.sock` | Shell sessions (`dockma shell`), proxied to the guest agent |
| `daemon.lock` | Held by the running daemon, so a second one can't boot another VM on the same disk |
| `config.json` | Settings |
| `data.img` | Sparse raw disk, ext4, mounted at `/var/lib/docker` in the guest |
| `guest/Image`, `guest/initramfs.cpio.lz4` | Guest kernel and initramfs |
| `guest/guest-protocol` | The host↔guest protocol number the guest was built for. `dockma start` refuses a guest that doesn't match. |
| `logs/console.log` | Kernel and init output; the previous boot is kept as `console.log.1` |
| `logs/docker.log` | dockerd output; the previous boot is kept as `docker.log.1` |
| `logs/daemon.log` | Host daemon output; the previous run is kept as `daemon.log.1` |
| `io.dockma.daemon.plist` | launchd job definition. With `--autostart true` it lives in `~/Library/LaunchAgents` instead. |

## How it works

```
macOS                                                   Linux guest
─────                                                   ───────────
docker CLI ──► ~/.dockma/docker.sock ┐                  busybox init
                                     │                   ├─ dockerd (+ containerd, runc)
dockma CLI ──► ~/.dockma/control.sock│                   └─ dockma-agent
dockma shell ► ~/.dockma/shell.sock  │                        │
                                     ▼                        │
            dockma daemon (launchd job io.dockma.daemon)      │
            owns the VZVirtualMachine                         │
              ├─ unix socket → vsock 1024 ───────────────────►├─► /var/run/docker.sock
              ├─ control      ◄─ vsock 1025 (JSON lines) ─────┤◄─ dialled by the agent: Docker ready,
              │                                               │   ports, time sync, shutdown
              ├─ 127.0.0.1:P  → vsock 1026 (TCP/UDP tunnel) ─►├─► 127.0.0.1:P (docker-proxy)
              └─ shell.sock   → vsock 1027 (shell frames) ───►└─► /bin/sh on a pty or pipes

  virtio-console hvc0/hvc1 → logs/console.log, logs/docker.log
  virtiofs "home"          → $HOME mounted at the same path
  virtiofs "rosetta"       → /mnt/rosetta, registered with binfmt_misc
  virtio-blk data.img      → ext4 on /var/lib/docker
  virtio-net (NAT), virtio-rng, virtio-balloon, PL031 RTC
```

**Host side (Swift).** A `VZVirtualMachine` lives only as long as the process that created it, so `dockma start` installs a launchd job that runs `dockma daemon`. The daemon:
- boots the VM;
- serves `docker.sock` and `shell.sock`, piping each connection to the guest over vsock;
- accepts the control connection that the guest agent opens as soon as it runs;
- mirrors the guest's published ports as listeners on the host.

`start` installs the job, then waits on `control.sock`, woken by kqueue events rather than a polling loop. Short fallback timers remain only for cases with no event to wait on, such as a daemon whose pid launchd hasn't reported yet. The daemon replies once the agent reports that dockerd's API answers. If the connection closes first, the daemon has exited, and `start` shows its log.

`stop` unloads the launchd job. The daemon then asks the agent to power the guest off, and hard-stops the VM after 20 s if that doesn't finish. launchd restarts the daemon if the guest powers off on its own or crashes. It does not restart it after a requested stop or a startup error, so a broken setup doesn't end up in a restart loop.

**Guest side.**
- **Stage-0 `/init`** moves the initramfs contents into a tmpfs and runs `switch_root`, because runc can't `pivot_root` out of the initramfs root.
- **busybox init** then:
  - mounts the pseudo filesystems and cgroup v2;
  - gets an address over DHCP;
  - prepares `/dev/vda` and mounts it at `/var/lib/docker`. A blank disk is formatted; an existing one is checked with `e2fsck -p` and grown if the host enlarged the image. A disk that holds data but no readable ext4 is never formatted: dockerd stays down and the console log names the recovery command;
  - mounts the home and Rosetta shares.
- **dockerd** runs with `firewall-backend: nftables`, so the guest ships `nft` instead of iptables and the kernel needs no xtables.
- **`dockma-agent`** (Go):
  - proxies vsock to the Docker socket;
  - dials the host's control port and reports when dockerd's API starts or stops answering. While dockerd is down it waits on inotify for the socket to appear rather than retrying;
  - watches the Docker events API for published TCP and UDP ports and reports them to the host;
  - dials tunnelled connections inside the VM. A UDP flow arrives as length-prefixed datagrams on one vsock connection per client;
  - runs `dockma shell` sessions. Each session uses a small framed protocol (start, stdin, resize, signal, started, stdout, stderr, exit, window) and runs on a pty or on pipes. `window` frames grant stdin credit, so a signal is never stuck behind stdin the command doesn't read;
  - steps the guest clock to host time every 30 s, which fixes drift after the Mac sleeps.

**Guest image.** `vm/Dockerfile` builds everything reproducibly with pinned versions: kernel 6.18.57, Docker 29.9.1 and moby's `check-config.sh` (all sha256-checked), Alpine 3.24 and Go 1.27. It has two build gates:
1. Every option in `vm/kernel/dockma.config` must survive `olddefconfig`, and every `# CONFIG_X is not set` line must stay disabled.
2. The kernel config must pass moby's `check-config.sh` required list. The iptables-only options are exempt because of the nftables backend.

The result is an 8.6 MB kernel and a 65 MB lz4 initramfs that unpacks to about 163 MB in guest RAM. lz4 is larger than zstd (42 MB) but unpacks in about 75 ms instead of 185 ms, which is most of the kernel's boot time.

## Development

```sh
make build          # debug build + ad-hoc codesign with dockma.entitlements
make test           # unit tests (Swift Testing)
make e2e            # build, then scripts/e2e.sh against a real VM
make guest          # rebuild the guest; also runs the agent's go vet / go test
make install-guest  # copy the rebuilt guest to ~/.dockma/guest
make site           # build the website into site/public (needs Hugo)
make site-serve     # preview the website locally
scripts/bench.sh    # boot and network benchmark; restarts the VM RUNS times (default 5)
```

`scripts/e2e.sh` pins `DOCKER_HOST` to dockma's socket and checks:
- that the engine answering is dockma's;
- hello-world;
- the home bind mount;
- stdin half-close;
- localhost port forwarding and its removal, for TCP and for UDP on the same port;
- Rosetta;
- logs;
- persistence across restart, plus a registry pull;
- a graceful stop.

It starts, restarts and stops your dockma VM.

To run the daemon in the foreground for debugging, stop the launchd job first (`dockma stop`). Then run `.build/debug/dockma daemon` and stop it with Ctrl-C.

### Layout

```
Package.swift, Makefile, dockma.entitlements
Sources/DockmaCore/       core library, grouped by area:
  VM/                     VM configuration, VZ wrapper, kernel cmdline, entitlement check
  Daemon/                 daemon lifecycle, launchd job, CLI↔daemon control protocol
  Agent/                  control link to dockma-agent
  Forwarding/             socket listeners, byte copying, vsock proxies, port forwarding
  Shell/                  `dockma shell` protocol and client session
  Settings/               config.json and the state directory layout
  Support/                logging, line I/O, subprocess runner, docker context
Sources/DockmaCLI/        the `dockma` command (swift-argument-parser)
Tests/DockmaCoreTests/    unit tests
vm/Dockerfile             guest build (kernel, rootfs, initramfs)
vm/kernel/                Kconfig fragment and Docker requirements gate
vm/rootfs/                init scripts, inittab, dockerd config, DHCP hook
vm/agent/                 dockma-agent (Go) with tests
vm/tests/                 guest script tests, run during the guest build
scripts/e2e.sh            end-to-end test
scripts/bench.sh          boot, network and disk benchmark (restarts the VM)
scripts/bench-build-steps.py  per-step build times and extracted layers, for bench.sh
site/                     website (Hugo): templates, data, fonts; deployed to GitHub Pages by .github/workflows/pages.yml
scripts/site-prepare.py   derives the site's version facts (vm/Dockerfile) and command reference (docc file)
scripts/release-notes.py  prints a version's CHANGELOG.md section, for release.yml
.github/workflows/        cli.yml, guest.yml (CI builds and tests), release.yml (drafts a release from a tag), pages.yml
```

### Releases

CI builds each half on pushes to `main` and pull requests that touch it:
- `cli.yml` runs `make test` and builds the signed release binary on GitHub's `xcode-27` runner (Xcode 27.1, Swift 6.4). It also fails if the committed docc reference is stale.
- `guest.yml` runs `make guest` on an arm64 Ubuntu runner, with a BuildKit cache.

Pushing a version tag (`0.2.0`, no `v`) runs `release.yml`. It rebuilds both from the tag without a cache, and drafts a GitHub release with the tarballs, `SHA256SUMS` and build provenance attestations. The notes are the tag's `CHANGELOG.md` section, and the workflow fails without one. Publish the draft by hand. For a tag pushed before `release.yml` existed, run the workflow manually with that tag.

The workflows don't run `make e2e`: hosted macOS runners can't start a VM.

## Troubleshooting

- **`dockma start` says the binary lacks the entitlement.** You ran a plain `swift build`. Run `make build` or `make install`, then start again.
- **`dockma start` times out or the daemon exits during startup.** On a terminal, `start` and `stop` show the latest console and daemon log lines in a small live panel while they wait. On failure, `start` prints the relevant log tail. Check it in full with `dockma logs --daemon` and `dockma logs`.
- **A guest image is missing.** Run `make guest install-guest`.
- **`docker` talks to a different engine.** Check `echo $DOCKER_HOST` and `docker context show`.
- **dockerd doesn't start and `dockma logs` says the data disk is not mounted.** The guest refuses to format a disk that holds data. `dockma shell` still works: run `dockma shell -- e2fsck -fy /dev/vda`, which can recover a damaged superblock from a backup copy, then `dockma restart`.
- **A published port isn't forwarded.** Run `dockma logs --daemon`. If the host port is already in use, the daemon logs `cannot forward port …`. macOS itself holds some UDP ports, such as 5353 (mDNS), so publish those on another host port.

## Limitations

- SCTP ports aren't forwarded.
- With `--port-bind-address 0.0.0.0` on a Mac with several addresses, a UDP reply can leave from a different address than the one the client sent to. Clients that check the reply's source may ignore it. TCP is unaffected.
- A UDP port tracks at most 256 clients; a new client beyond that ends the least recently active one. Datagrams beyond 16 MiB waiting for the VM are dropped.
- The guest root filesystem lives in RAM (about 163 MB). A read-only erofs root would avoid that.
- The memory balloon device is attached, but nothing reclaims memory from the guest yet.
- If the guest agent is unresponsive, `stop` hard-stops the VM after 2 s. Recent writes that ext4 hasn't flushed can be lost.
- `dockma shell` depends on the guest agent. If the agent itself is dead, there is no way in short of `dockma restart`.
- Not yet tested:
  - growing the disk with `config --disk`;
  - `--autostart`;
  - `delete`;
  - home paths that contain spaces.

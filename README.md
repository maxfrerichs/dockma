# dockma

Lightweight Docker on macOS, free and open source. Website and command reference: <https://dockma.dev>

## tl;dr

dockma runs the Docker Engine in a minimal Linux VM on Apple's Virtualization.framework. The macOS `docker` CLI communicates via a Unix socket. A launchd job keeps it running, and your home directory is shared into the VM.

> **Status:** early and experimental, tested only on Apple Silicon with macOS 27. Read the [Limitations](#limitations).

## Features

| Feature | What you get |
|---|---|
| Minimal guest | A custom 6.18 LTS kernel with only what Docker needs, no modules, and a busybox initramfs with Docker's static binaries. Docker is ready about 0.6 s after boot starts. |
| Shared home | `$HOME` is mounted into the VM at the same path, so `docker run -v "$PWD:/src"` works anywhere under it. |
| Ports on localhost | `-p 8080:80` answers on `localhost:8080` (IPv4 and IPv6), UDP included. Ports below 1024 work too ([details](#ports-below-1024)). |
| Containers reach the Mac | `host.docker.internal` and `--add-host name:host-gateway` resolve to the Mac, as on Docker Desktop. A Mac service must listen on more than `127.0.0.1` to be reachable. |
| amd64 images | `--platform linux/amd64` runs through Rosetta for Linux. |
| Runs in the background | A launchd job keeps the VM up and restarts it if the guest crashes. |
| Shell in the VM | `dockma shell` opens a root shell, even when dockerd is broken. |
| Graceful shutdown | `dockma stop` powers the guest off cleanly. Images, containers and volumes persist on a sparse disk image. |

## Requirements

- An Apple Silicon Mac, macOS 14 or later (only macOS 27 is tested).
- The `docker` CLI, e.g. `brew install docker`. dockma provides the engine, not the client.
- Optional: Rosetta for amd64 images (`softwareupdate --install-rosetta`).
- Building from source also needs Xcode with Swift 6.4, and an arm64 Docker engine with buildx for the guest (Lima, Colima, Docker Desktop, or dockma itself once it runs). The guest build downloads from kernel.org, download.docker.com, GitHub, Docker Hub and the Go module proxy.

## Quick start

### With the install script

```sh
curl -fsSL https://dockma.dev/install.sh | sh
dockma start
docker context use dockma
```

[`install.sh`](install.sh) installs the newest release:

1. It downloads the CLI tarball and checks it against the release's `SHA256SUMS`, and against its build attestation when a logged-in `gh` is available.
2. It fetches the matching guest with `dockma install`. If that fails, nothing changes.
3. It installs `dockma` to `~/.local/bin`, and tells you if that isn't on your `PATH`.

It doesn't start the VM or edit your shell profile. Run it again to upgrade.

| Variable | Effect |
|---|---|
| `DOCKMA_VERSION` | Install this release (0.3.0 or later) instead of the newest |
| `DOCKMA_INSTALL_DIR` | Install the binary here instead of `~/.local/bin` |
| `DOCKMA_SKIP_GUEST=1` | Install only the CLI; run `dockma install` later |
| `DOCKMA_RELEASE_URL` | Read release assets from this URL or absolute path instead of GitHub. Needs `DOCKMA_VERSION`; `dockma install` reads it too. |

### From a release

Each [release](../../releases) has the CLI (`dockma-<version>-macos-arm64.tar.gz`), the guest (`dockma-linux-<version>-arm64.tar.gz`) and `SHA256SUMS`.

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
xattr -d com.apple.quarantine dockma-*-macos-arm64.tar.gz   # only if a browser downloaded it
mkdir -p ~/.local/bin
tar -xzf dockma-*-macos-arm64.tar.gz -C ~/.local/bin dockma
dockma install          # fetches and verifies this version's guest into ~/.dockma/guest
dockma start
docker context use dockma
```

- The binary is ad-hoc signed, not notarized. macOS kills a quarantined copy at launch, hence the `xattr` step for browser downloads.
- `gh attestation verify <file> --repo <owner>/dockma` checks that a tarball came from this repository's release workflow.
- `dockma install` replaces the guest atomically; a running VM keeps the old one until `dockma restart`.
- `dockma start` (and `restart`) runs `dockma install` itself when no guest is installed, or when the installed one came from another release. It never replaces a guest from `make install-guest` or one installed before 0.6; `DOCKMA_NO_AUTO_INSTALL=1` turns it off. Offline, unpack the guest tarball into `~/.dockma/guest` yourself.

### From source

```sh
make guest install-guest     # build the guest kernel and initramfs, copy them to ~/.dockma/guest
make install                 # build, sign and install ~/.local/bin/dockma
dockma start
docker context use dockma    # or: export DOCKER_HOST=unix://$HOME/.dockma/docker.sock
docker run --rm hello-world
```

> **Never use plain `swift build`.** It produces a binary without the `com.apple.security.virtualization` entitlement, and `dockma start` refuses to run it. Use `make build` or `make install`.

A `DOCKER_HOST` that is already set (Lima sets one, for example) overrides docker contexts. Unset it or point it at dockma's socket; `dockma start` and `dockma status` warn about it.

## Usage

| Command | Does |
|---|---|
| `dockma install` | Download this version's guest into `~/.dockma/guest` |
| `dockma start [--timeout <s>]` | Start the VM and wait until Docker answers |
| `dockma stop` | Shut the VM down gracefully |
| `dockma restart [--timeout <s>]` | Stop, then start |
| `dockma status [--json]` | State, uptime, resources, kernel, forwarded ports |
| `dockma shell [-t\|-T] [-- cmd …]` | Root shell in the VM, or run one command there |
| `dockma logs [--docker\|--daemon] [-n N] [-f]` | VM console log, dockerd's log, or the host daemon's log |
| `dockma config [options]` | Show or change settings |
| `dockma delete [-f]` | Delete the data disk (all images, containers, volumes), config and logs |
| `dockma --version` | Print the version |

```console
$ dockma status
state:    running
docker:   ready (/Users/you/.dockma/docker.sock)
uptime:   12m 4s
vm:       6 CPUs, 4096 MiB, kernel 6.18.57-dockma
agent:    connected 0.6.1
ports:    8080, 1053/udp
daemon:   pid 55658
```

### Shell

```console
$ dockma shell                       # interactive root login shell
$ dockma shell -- uname -r           # one command; stdout, stderr and exit code pass through
$ echo data | dockma shell -- cat    # stdin is forwarded
```

- Like ssh, it uses a pseudo-terminal when stdin is a terminal and plain pipes for a command. `-t` forces a terminal and `-T` disables it.
- Ctrl-C reaches the remote program. If the client goes away, the remote process gets SIGHUP, then SIGKILL after 2 s.
- A missing command exits with 127. There is no `~.` escape: if the agent hangs, kill `dockma shell` from another terminal.
- It talks to the guest agent, not Docker, so it works while dockerd is down. `docker` isn't installed in the VM; use `docker exec` from macOS for containers.
- The interactive shell greets you with a whale quip and a status line. `dockma shell -- /usr/libexec/dockma-motd --all` lists every quip.

### Configuration

`dockma config` without options prints the settings. Changes apply on the next `dockma restart`.

| Option | Default | Description |
|---|---|---|
| `--cpus <n>` | half the host's cores (min. 2) | Virtual CPUs |
| `--memory <MiB>` | `4096` | Guest memory |
| `--disk <GiB>` | `64` | Sparse data disk. It can only grow. |
| `--port-bind-address <ip>` | `127.0.0.1` | Where published ports bind. Loopback also binds `::1`; `0.0.0.0` also binds `::` and exposes ports to your network. |
| `--rosetta <bool>` | `true` | Attach Rosetta for amd64 images |
| `--autostart <bool>` | `false` | Start dockma at login (installs the plist into `~/Library/LaunchAgents`) |

Settings live in `~/.dockma/config.json`, along with a generated MAC address that keeps the VM's IP stable. `config` warns when `--cpus` exceeds the Mac's cores or `--memory` 75% of its RAM.

#### Docker daemon settings and certificates

The VM's root filesystem is rebuilt on every boot, so changes made in `dockma shell` don't last. Put them in the state directory; they apply on the next `dockma restart`:

| Path | Effect |
|---|---|
| `~/.dockma/daemon.json` | Merged over dockma's dockerd configuration (registry mirrors, `proxies`, `default-address-pools`, `log-opts`, …). `hosts`, `group`, `data-root` and `firewall-backend` stay dockma's. If dockerd rejects the result, it starts with dockma's configuration and `dockma logs --docker` says why. |
| `~/.dockma/ca-certificates/*.crt` | Extra CA certificates, e.g. for a TLS-intercepting proxy |
| `~/.dockma/certs.d/` | Per-registry certificates in Docker's [`certs.d` layout](https://docs.docker.com/engine/security/certificates/) |

dockma's own defaults, which `daemon.json` can override: container logs are capped at three 10 MB files, and `host-gateway` is the Mac. The guest reads these files over the home share, so a `DOCKMA_HOME` outside your home directory can't use them.

### Ports below 1024

macOS lets a non-root process bind a low port only on the wildcard address. So with a loopback bind address, dockma listens on `0.0.0.0` and `::` and closes connections (or drops datagrams) from anything but loopback. Consequences:

- A port scan from the network sees the TCP port as open (the handshake completes before the close), and a UDP port as `open|filtered`.
- Anything else listening on `*:80` conflicts. A root process holding `127.0.0.1:80` wins, and dockma's listener gets none of that traffic.
- macOS may ask whether `dockma` may accept incoming connections. The listener stays loopback-only whatever you answer.
- `dockma logs --daemon` shows the first rejected peer on each listener.

### Files

Everything lives under `~/.dockma`, or `DOCKMA_HOME` (socket paths must stay under 104 bytes). Each state directory is a separate VM with its own launchd job; only `~/.dockma` gets the `dockma` docker context. The directory and `logs/` are kept at mode 0700, the disk, config and logs at 0600, reset on every start.

| Path | Contents |
|---|---|
| `docker.sock`, `control.sock`, `shell.sock` | Docker API, CLI↔daemon control, and shell sessions |
| `config.json` | Settings |
| `daemon.json`, `ca-certificates/`, `certs.d/` | Optional dockerd settings, see [above](#docker-daemon-settings-and-certificates) |
| `data.img` | Sparse ext4 disk, mounted at `/var/lib/docker` in the guest |
| `guest/` | Guest kernel, initramfs and its protocol number, from `dockma install` or `make install-guest`; `origin` says which (`release <version>` or `local`) |
| `logs/console.log`, `docker.log`, `daemon.log` | Kernel and init, dockerd, and host daemon output; rotated at each start and past 10 MB, with three previous generations kept as `.1`–`.3` |
| `daemon.lock`, `.guest-install.lock` | Held by the running daemon and by a running `dockma install` |
| `io.dockma.daemon.plist` | The launchd job (`io.dockma.daemon.<hash>.plist` for a `DOCKMA_HOME`; in `~/Library/LaunchAgents` with autostart) |

### Uninstall

```sh
dockma stop
dockma delete --force      # data disk, config, logs, launchd plists, docker context
rm -rf ~/.dockma           # the guest and anything left
rm ~/.local/bin/dockma     # or wherever you installed it
```

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

  virtio-console ports    → "console" (hvc0) → logs/console.log, "docker" → logs/docker.log
  virtiofs "home"          → $HOME mounted at the same path
  virtiofs "rosetta"       → /mnt/rosetta, registered with binfmt_misc
  virtio-blk data.img      → ext4 on /var/lib/docker
  virtio-net (NAT), virtio-rng, virtio-balloon, PL031 RTC
```

**Host (Swift).** A `VZVirtualMachine` lives only as long as its process, so `dockma start` installs a launchd job that runs `dockma daemon`. The daemon boots the VM, pipes `docker.sock` and `shell.sock` to the guest over vsock, accepts the agent's control connection, and mirrors the guest's published ports on the host. It watches the bind-mount sources the agent names with FSEvents and sends their changes to the guest.

- `start` waits on `control.sock`, woken by kqueue events. The daemon answers once the agent reports dockerd's API up; if the connection closes first, `start` shows the daemon's log.
- `stop` unloads the job. The daemon asks the agent to power off and hard-stops the VM after 25 s (2 s without an agent).
- launchd restarts the daemon when the guest powers off on its own or crashes, but not after a requested stop or a startup error. A guest kernel panic reboots the guest in place after 5 s, and the agent reconnects.

**Guest.**

- **Stage-0 `/init`** moves the initramfs into a tmpfs and runs `switch_root`, because runc can't `pivot_root` out of the initramfs.
- **busybox init** mounts cgroup v2 and the pseudo filesystems, gets an address over DHCP, mounts the home and Rosetta shares, and adds your CA certificates. It mounts `/dev/vda` at `/var/lib/docker`: a blank disk is formatted, an existing one checked with `e2fsck -p` and grown if the image grew. A disk with data but no readable ext4 is never formatted; dockerd stays down and the console log names the recovery command.
- **dockerd** uses `firewall-backend: nftables`, so the guest ships `nft`, not iptables. Its configuration is generated before each start from the baked `daemon.json`, yours, and dockma's defaults. The kernel also has what Docker-in-Docker, kind, k3s and k3d need in containers: iptables-nft for both address families, ipset, VXLAN, nfqueue and conntrack labels, plus `/dev/net/tun`. `/proc/config.gz` lists everything.
- **`dockma-agent`** (Go):
  - proxies vsock to the Docker socket, and dials tunnelled TCP and UDP connections inside the VM;
  - dials the host's control port and reports Docker readiness (waiting on inotify while dockerd is down) and published ports (from the Docker events API), and names the bind-mount sources under home to watch;
  - turns changes made on the Mac to those sources into inotify events in containers (`/proc/fs/dockma-notify`), dropping the echoes of the guest's own writes;
  - runs `dockma shell` sessions on a pty or pipes, with stdin flow control so signals never wait behind unread input;
  - steps the guest clock to the host's every 30 s, which fixes drift after the Mac sleeps;
  - serves DNS on port 10053, reached through an nftables redirect of the VM's port 53: it answers `host.docker.internal` itself and relays the rest to the DHCP lease's servers. Port 53 stays free for containers like Pi-hole; containers that query such a server at the VM's address reach the agent instead, so point them at it by name or container IP;
  - runs `fstrim` hourly, so `data.img` shrinks after you delete images;
  - accepts vsock connections only from the host (CID 2); the kernel has no vsock loopback.

**Guest image.** `vm/Dockerfile` builds everything with pinned, sha256-checked versions: kernel 6.18.57, Docker 29.9.1, Alpine 3.24 and Go 1.27. The build fails if an option in `vm/kernel/dockma.config` doesn't survive `olddefconfig`, or the config misses an entry on moby's `check-config.sh` required list (iptables-only options are exempt). The result is a 9.6 MB kernel and a 68 MB lz4 initramfs that unpacks to about 163 MB of guest RAM. lz4 is larger than zstd but unpacks in about 75 ms instead of 185 ms.

## Development

```sh
make build          # debug build, ad-hoc signed with dockma.entitlements
make test           # unit tests (Swift Testing)
make e2e            # build, then scripts/e2e.sh against a real VM
make guest          # rebuild the guest; also runs the agent's go vet and go test
make install-guest  # copy the guest to $DOCKMA_HOME/guest (default ~/.dockma/guest)
make site           # build the website into site/public (needs Hugo); make site-serve previews it
scripts/bench.sh          # boot phase breakdown; restarts the VM RUNS times (default 5)
scripts/bench-compare.py  # dockma vs Lima vs OrbStack; see docs/benchmarks.md
```

`make e2e` runs against its own VM in `~/.dockma-e2e`, so yours keeps running; it still mounts your real home. That VM's guest is copied from `~/.dockma/guest` if missing; test a fresh build with `make guest install-guest DOCKMA_HOME=~/.dockma-e2e`. The suite pins `DOCKER_HOST` to dockma's socket and covers forwarding (TCP, UDP, held ports), `host.docker.internal`, bind mounts, Docker-in-Docker, Rosetta, `daemon.json`, persistence across restart and a graceful stop.

To debug the daemon in the foreground: `dockma stop`, then `.build/debug/dockma daemon`, and Ctrl-C to stop it.

### Layout

```
Sources/DockmaCore/   core library: VM, Daemon, Agent, Forwarding, Shell, Settings, Terminal, Support
Sources/DockmaCLI/    the dockma command (swift-argument-parser)
Tests/DockmaCoreTests/
vm/Dockerfile         guest build; vm/kernel/ (Kconfig fragment), vm/rootfs/ (init scripts, configs)
vm/agent/             dockma-agent (Go) and its tests; vm/tests/ (guest script tests)
scripts/              e2e.sh, benchmarks, site-prepare.py, release-notes.py
site/                 website (Hugo), deployed by .github/workflows/pages.yml
.github/workflows/    cli.yml, guest.yml, lint.yml, release.yml, pages.yml
```

### Releases

- CI builds both halves on pushes to `main` and on pull requests: `cli.yml` (tests, signed binary, docc freshness) on the `xcode-27` runner, `guest.yml` on an arm64 Ubuntu runner, and `lint.yml` (actionlint, shellcheck).
- Pushing a version tag (`0.2.0`, no `v`) runs `release.yml`. It rebuilds both without a cache and drafts a release with the tarballs, `SHA256SUMS`, attestations and the tag's `CHANGELOG.md` section. Publish the draft by hand.
- CI can't run `make e2e`: hosted macOS runners can't start a VM.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `dockma start` says the binary lacks the entitlement | You ran plain `swift build`. Use `make build` or `make install`. |
| `start` times out, or the daemon exits during startup | `start` prints the relevant log tail; read it in full with `dockma logs --daemon` and `dockma logs`. |
| The guest image is missing | `dockma install`, or `make guest install-guest` for a source build. |
| `docker` talks to another engine | Check `echo $DOCKER_HOST` and `docker context show`. |
| dockerd is down and `dockma logs` says the data disk isn't mounted | The guest won't format a disk holding data. Run `dockma shell -- e2fsck -fy /dev/vda`, then `dockma restart`. |
| A published port isn't forwarded | `dockma status` warns when a Mac process holds the port; dockma takes it within 10 s of it being freed. macOS holds some UDP ports itself (5353 for mDNS): publish on another host port. |
| A bind mount is empty | Only your home directory is shared. Paths like `/tmp`, `/Volumes/…` or `$TMPDIR` mount empty, without an error. For Testcontainers and similar, set e.g. `TMPDIR=~/.cache/tmp`. |
| `x509: certificate signed by unknown authority` | A proxy re-signs TLS. Put its CA in `~/.dockma/ca-certificates/` and `dockma restart`. |

## Limitations

- **Sharing:** only your home directory is shared with the VM.
- **Ports:**
  - SCTP isn't forwarded.
  - Each UDP client gets its own tunnel, which ends 90 s after its last packet, as with docker-proxy.
  - With `--port-bind-address 0.0.0.0` on a Mac with several addresses, a UDP reply can leave from a different address than the client used.
  - A UDP port tracks at most 256 clients (a new one ends the least recently active), and drops datagrams beyond 16 MiB queued for the VM.
- **Memory:**
  - The guest root filesystem lives in RAM (about 163 MB).
  - The balloon device is attached, but nothing reclaims guest memory yet.
- **Shutdown:** a stop that runs out of time hard-stops the VM (after 25 s, or 2 s without an agent), and unflushed ext4 writes can be lost.
- **Trust:**
  - Whatever can write the state directory controls the VM as root on the next boot, through `daemon.json`, `ca-certificates/` and `certs.d/`.
  - A privileged container, or one without seccomp, can open vsock and pose as the agent. Such a container controls the VM anyway.
- **File events:** changes on the Mac fire inotify events only for bind mounts under home, and only while the agent is connected; changes made during a guest reboot are missed. A container's own delete raises a second `DELETE` when the Mac reports it back. If FSEvents drops events, or a burst of changes overflows the agent's queue, those changes raise none. At most 256 mounts are watched.
- **Shell:** `dockma shell` needs a live agent. If the agent is dead, only `dockma restart` gets you in.
- **GPU:** containers get no GPU acceleration. macOS 27 could carry a virtio-gpu device with Venus (Vulkan only), but dockma doesn't implement one. For GPU work, use a krunkit-based engine or run natively.
- **Untested:** `--autostart`, `delete`, and home paths containing spaces.

# dockma

Docker on macOS in a minimal Linux VM.

dockma boots a small Linux VM with Apple's Virtualization.framework whose only job is to run the Docker Engine. The macOS `docker` CLI talks to that engine through a unix socket, and your home directory is shared into the VM. A small CLI starts and stops the VM and shows its logs.

- **Minimal guest.**
  - Kernel: a custom 6.18 LTS kernel built from `tinyconfig` plus only the drivers and features Docker needs. Everything is built in, with no modules.
  - Userspace: a busybox initramfs containing Docker's static binaries and a small guest agent.
  - It boots to a ready Docker engine in about a second.
- **Home directory at the same path.**
  - `$HOME` is mounted inside the VM at the identical path (for example `/Users/you`) via virtiofs.
  - So `docker run -v "$PWD:/src"` works from anywhere under your home directory.
- **Published ports on localhost.**
  - `docker run -p 8080:80 …` is reachable at `localhost:8080` (IPv4 and IPv6), with no manual forwarding.
  - The listener goes away when the container stops.
- **amd64 images via Rosetta.**
  - `docker run --platform linux/amd64 …` runs x86-64 images through Rosetta for Linux.
- **Runs in the background.**
  - A per-user launchd job keeps the VM running after the CLI exits.
  - It restarts the VM if the guest dies unexpectedly.
- **A shell in the VM.**
  - `dockma shell` opens a root shell inside the VM; `dockma shell -- <cmd>` runs a single command there.
  - It goes through the guest agent rather than Docker, so it still works when dockerd is broken.
- **Graceful shutdown.**
  - `dockma stop` asks the guest to stop dockerd and power off cleanly.
  - Your images, containers and volumes persist on a sparse disk image.

> **Status:** early and experimental. It has only been tested on Apple Silicon with macOS 27. Expect rough edges; see [Limitations](#limitations).

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
dockma restart                    Stop, then start
dockma status [--json]            State, uptime, resources, guest kernel, forwarded ports
dockma shell [-t|-T] [-- cmd …]   Root shell in the VM, or run a command there
dockma logs [-n N] [-f]           Kernel and boot log of the VM
dockma logs --docker [-n N] [-f]  dockerd's log
dockma logs --daemon [-n N] [-f]  Log of the host-side daemon (VM lifecycle, port forwards)
dockma config [options]           Show or change settings (applied on next start)
dockma delete [-f]                Delete the data disk (all images, containers, volumes), config and logs
```

Example:

```console
$ dockma status
state:    running
docker:   ready (/Users/you/.dockma/docker.sock)
uptime:   12m 4s
vm:       6 CPUs, 4096 MiB, kernel 6.18.57
agent:    connected 0.2.0
ports:    8080
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
| `--port-bind-address <ip>` | `127.0.0.1` | Host address that published ports bind to. With `127.0.0.1` they're also bound on `::1`; with `0.0.0.0`, also on `::`. Use `0.0.0.0` to expose them to your network. |
| `--rosetta <bool>` | `true` | Attach Rosetta for amd64 images |
| `--autostart <bool>` | `false` | Start dockma at login. This installs the launchd plist into `~/Library/LaunchAgents`. |

Settings are stored in `~/.dockma/config.json`. The VM's MAC address is generated once and stored there, so the VM keeps the same NAT IP across restarts.

### Files

Everything lives under `~/.dockma`. You can override the location with `DOCKMA_HOME`, but socket paths must stay under 104 bytes.

| Path | Contents |
|---|---|
| `docker.sock` | Docker API socket for the macOS `docker` CLI |
| `control.sock` | CLI ↔ daemon control socket |
| `shell.sock` | Shell sessions (`dockma shell`), proxied to the guest agent |
| `config.json` | Settings |
| `data.img` | Sparse raw disk, ext4, mounted at `/var/lib/docker` in the guest |
| `guest/Image`, `guest/initramfs.cpio.zst` | Guest kernel and initramfs |
| `logs/console.log` | Kernel and init output; the previous boot is kept as `console.log.1` |
| `logs/docker.log` | dockerd output; the previous boot is kept as `docker.log.1` |
| `logs/daemon.log` | Host daemon output (appended across runs) |
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
              ├─ control      ◄─ vsock 1025 (JSON lines) ────►├─  ports, time sync, shutdown
              ├─ 127.0.0.1:P  → vsock 1026 (TCP tunnel) ─────►├─► 127.0.0.1:P (docker-proxy)
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
- keeps a control connection to the guest agent;
- mirrors the guest's published ports as listeners on the host.

`stop` unloads the launchd job. The daemon then asks the agent to power the guest off, and hard-stops the VM after 20 s if that doesn't finish. launchd restarts the daemon if the guest powers off on its own or crashes. It does not restart it after a requested stop or a startup error, so a broken setup doesn't end up in a restart loop.

**Guest side.**
- **Stage-0 `/init`** moves the initramfs contents into a tmpfs and runs `switch_root`, because runc can't `pivot_root` out of the initramfs root.
- **busybox init** then:
  - mounts the pseudo filesystems and cgroup v2;
  - gets an address over DHCP;
  - formats `/dev/vda` on first boot (and grows it if the host enlarged the image), then mounts it at `/var/lib/docker`;
  - mounts the home and Rosetta shares.
- **dockerd** runs with `firewall-backend: nftables`, so the guest ships `nft` instead of iptables and the kernel needs no xtables.
- **`dockma-agent`** (Go):
  - proxies vsock to the Docker socket;
  - watches the Docker events API for published TCP ports and reports them to the host;
  - dials tunnelled connections inside the VM;
  - runs `dockma shell` sessions. Each session uses a small framed protocol (start, stdin, resize, signal, started, stdout, stderr, exit) and runs on a pty or on pipes;
  - steps the guest clock to host time every 30 s, which fixes drift after the Mac sleeps.

**Guest image.** `vm/Dockerfile` builds everything reproducibly with pinned versions: kernel 6.18.57, Docker 29.9.1 (sha256-checked), Alpine 3.24 and Go 1.27. It has two build gates:
1. Every option in `vm/kernel/dockma.config` must survive `olddefconfig`.
2. The kernel config must pass moby's `check-config.sh` required list. The iptables-only options are exempt because of the nftables backend.

The result is a 7.3 MB kernel and a 42 MB zstd initramfs that unpacks to about 163 MB in guest RAM.

## Development

```sh
make build          # debug build + ad-hoc codesign with dockma.entitlements
make test           # unit tests (Swift Testing)
make e2e            # build, then scripts/e2e.sh against a real VM
make guest          # rebuild the guest; also runs the agent's go vet / go test
make install-guest  # copy the rebuilt guest to ~/.dockma/guest
```

`scripts/e2e.sh` pins `DOCKER_HOST` to dockma's socket and checks:
- that the engine answering is dockma's;
- hello-world;
- the home bind mount;
- stdin half-close;
- localhost port forwarding and its removal;
- Rosetta;
- logs;
- persistence across restart, plus a registry pull;
- a graceful stop.

It starts, restarts and stops your dockma VM.

To run the daemon in the foreground for debugging, stop the launchd job first (`dockma stop`). Then run `.build/debug/dockma daemon` and stop it with Ctrl-C.

### Layout

```
Package.swift, Makefile, dockma.entitlements
Sources/dockma/           core library: VM configuration, daemon, forwarding, launchd, control protocol
Sources/DockmaCLI/        the `dockma` command (swift-argument-parser)
Tests/dockmaTests/        unit tests
vm/Dockerfile             guest build (kernel, rootfs, initramfs)
vm/kernel/                Kconfig fragment and Docker requirements gate
vm/rootfs/                init scripts, inittab, dockerd config, DHCP hook
vm/agent/                 dockma-agent (Go) with tests
scripts/e2e.sh            end-to-end test
```

## Troubleshooting

- **`dockma start` says the binary lacks the entitlement.** You ran a plain `swift build`. Run `make build` or `make install`, then start again.
- **`dockma start` times out or the daemon exits during startup.** `start` prints the relevant log tail. Check it in full with `dockma logs --daemon` and `dockma logs`.
- **A guest image is missing.** Run `make guest install-guest`.
- **`docker` talks to a different engine.** Check `echo $DOCKER_HOST` and `docker context show`.
- **A published port isn't forwarded.** Run `dockma logs --daemon`. If the host port is already in use, the daemon logs `cannot forward port …`.

## Limitations

- Only TCP ports are forwarded; UDP is not.
- The guest root filesystem lives in RAM (about 163 MB). A read-only erofs root would avoid that.
- The memory balloon device is attached, but nothing reclaims memory from the guest yet.
- If the guest agent is unresponsive, `stop` hard-stops the VM after 2 s. Recent writes that ext4 hasn't flushed can be lost.
- `dockma shell` depends on the guest agent. If the agent itself is dead, there is no way in short of `dockma restart`.
- Not yet tested:
  - growing the disk with `config --disk`;
  - `--autostart`;
  - `delete`;
  - home paths that contain spaces.
- The kernel and userspace are custom builds. Supporting a new Docker feature can require a new kernel option in `vm/kernel/dockma.config`.

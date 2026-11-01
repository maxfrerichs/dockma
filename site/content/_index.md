---
# The homepage. Its text lives here; layouts/index.html only arranges it.
# Placeholders, filled in at build time:
#   {kernel} {kernelSeries} {docker}  versions pinned in vm/Dockerfile
#   {boot}                            params.bootSeconds in hugo.toml
#   {installURL}                      this site's install.sh
#   {repo}                            the GitHub repository's URL
# Each "## Heading {#id}" starts a section. A ```sh block gets a copy button
# that skips "#" comments; ```sh {.install} is the one-line install command;
# a ```console block is output, with "$ " marking the command.
# A {.class} line under a paragraph or list sets its CSS class.
tagline:
  - "Lightweight Docker on macOS,"
  - "free and open source."
status: "**Status:** early development · Apple Silicon only · tested on macOS 27"
features:
  - title: "Boots in ~{boot}s"
    body: "A custom-built {kernelSeries} LTS kernel with only what Docker needs, and a busybox userspace."
  - title: "Shared $HOME directory"
    body: 'Your home directory is shared via virtiofs at the identical path, so `-v "$PWD:/src"` just works.'
  - title: "Ports on localhost"
    body: "`-p 8080:80` is reachable at `localhost:8080`, IPv4 and IPv6. UDP (`-p 1053:53/udp`) and ports below 1024 work too. Gone when the container stops."
  - title: "Containers reach the Mac"
    body: "`host.docker.internal` and `--add-host name:host-gateway` resolve to your Mac, as on Docker Desktop."
  - title: "amd64 images via Rosetta"
    body: "`--platform linux/amd64` runs x86-64 images through Rosetta for Linux."
  - title: "dockma shell"
    body: "A root shell in the VM through the guest agent, so it works even when dockerd doesn't."
  - title: "Configurable"
    body: "`~/.dockma/daemon.json` is merged over dockerd's config. Add registry mirrors, proxies and your own CA certificates."
  - title: "VPNs, kind and k3s"
    body: "The kernel has `/dev/net/tun` for Tailscale, and what kind, k3s and Docker-in-Docker need, network policies included."
  - title: "A disk that gives space back"
    body: "A sparse data disk that grows with `dockma config --disk` and is trimmed hourly, so `data.img` shrinks on the Mac."
  - title: "Self-healing"
    body: "Runs under launchd and restarts after a guest crash; a kernel panic reboots the guest in 5 s. `dockma stop` powers off cleanly."
  - title: "Verified install"
    body: "One install script, checked against the release's `SHA256SUMS`. `dockma install` fetches the matching guest image."
  - title: "Free and open source"
    body: "MIT licensed. The whole guest builds from one Dockerfile with `make guest`, so you can read and rebuild all of it."
---

```sh {.install}
curl -fsSL {installURL} | sh
```

Installs the latest release to `~/.local/bin`, checksum-verified. [Read the script]({repo}/blob/main/install.sh) before you run it.
{.install-note}

## Docker on a Mac, without the hassle. {#why}

dockma is a Docker *runtime* for Apple Silicon Macs, an alternative to running the engine through Docker Desktop, Colima or OrbStack. It boots a minimal Linux VM with Apple's Virtualization.framework and runs Docker Engine inside it. You keep using the `docker` CLI on your host: it talks to the engine through a Unix socket, and a launchd job keeps the VM running in the background.

It is in early development. Feel free to install it, daily-drive it and report issues, and read the [known limitations]({repo}/blob/main/README.md#limitations) first. If you need a battle-tested, production-ready alternative, consider [Colima](https://github.com/abiosoft/colima).

## Features {#features}

{{< features >}}

## A VM built for one job {#vm}

The guest is not a general-purpose distribution. Everything in it exists to run Docker, and all of it is built from one Dockerfile.

- **Kernel:** Linux {kernel}, configured from `tinyconfig` with only what Docker needs. Everything is built in, with no modules.
- **Userspace:** a busybox initramfs with Docker {docker}'s static binaries. Its init keeps two services running: `dockma-agent`, a Go service on vsock, and `dockerd`.
- **Stateless root:** the root filesystem is rebuilt on every boot. Only `/var/lib/docker` lives on the data disk.
- **Verifiable:** kernel and Docker downloads are pinned and sha256-checked. Release builds carry provenance attestations.
{.facts}

## Quick start {#quick-start}

### Install a release {.sub}

```sh
# 1. Install the dockma CLI and its Linux guest from the latest release
curl -fsSL {installURL} | sh

# 2. Start the VM and point the docker CLI at it
dockma start
docker context use dockma
docker run --rm hello-world
```

Needs an Apple Silicon Mac with macOS 14 or later and the `docker` CLI (`brew install docker`). The [script]({repo}/blob/main/install.sh) checks the download against the release's `SHA256SUMS` (and its build attestation, if `gh` is logged in), installs `dockma` to `~/.local/bin` and fetches the matching Linux guest. Set `DOCKMA_VERSION` to pin a release or `DOCKMA_INSTALL_DIR` to install elsewhere. Optional: Rosetta for amd64 images. If `DOCKER_HOST` is set (Lima does this), it overrides the context.
{.note}

### From source {.sub}

```sh
# 1. Build the guest kernel and initramfs (needs an existing arm64 Docker engine).
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

Also needs Xcode with Swift 6.4, and any arm64 Docker engine with buildx for the first guest build.
{.note}

## At a glance {#status-demo}

```console
$ dockma status
state:    running
docker:   ready (/Users/you/.dockma/docker.sock)
uptime:   12m 4s
vm:       6 CPUs, 4096 MiB, kernel {kernel}
agent:    connected 0.7.2
ports:    8080, 1053/udp
daemon:   pid 55658 0.7.0
```

## How it works {#how}

{{< architecture >}}

A lightweight daemon owns the VM and pipes the Docker, shell and port connections to a Go agent in the guest over vsock.

[Full architecture →]({repo}/blob/main/README.md#how-it-works)

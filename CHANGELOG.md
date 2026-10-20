# Changelog

All notable changes to dockma are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are git tags without a `v` prefix. Before 1.0, a new feature or an incompatible host↔guest change bumps the minor version, and fixes bump the patch.

## Unreleased

### Changed
- `docker run` takes about 50 ms less, 120 instead of 170 ms for a container that exits at once. The guest kernel now uses expedited RCU grace periods, which container setup and teardown wait on. This is a kernel command line option set by the host, so the current guest gets it after `dockma restart`.
- The guest's logs leave through one virtio console device with named ports, "console" and "docker", instead of two console devices told apart by probe order. dockerd writes its log directly to the "docker" port, without a TTY or a wrapper pipe. The VM has one PCI device fewer, which shortens kernel boot by about 8 ms. This changes the guest protocol to 4: install the matching guest with `dockma install` (install.sh does this), or `make guest install-guest` for a source build.
- The guest's kernel and initramfs are named as LinuxKit names its kernel+initrd output: `~/.dockma/guest/dockma-kernel` and `dockma-initrd.img` (were `Image` and `initramfs.cpio.lz4`). `dockma install`, which install.sh runs, puts the new files in place. A CLI built from source needs `make guest install-guest` once; until then `dockma start` refuses with that hint.

## 0.5.0 – 2026-10-19

### Added
- The guest kernel's configuration is readable at `/proc/config.gz`, so tools in containers (moby's `check-config.sh`, `k3s check-config`) can see which features the kernel has. It has no modules, so the configuration is the full list.

### Changed
- The website lives at <https://dockma.dev>. The install command is `curl -fsSL https://dockma.dev/install.sh | sh`; the old `maxfrerichs.github.io/dockma/` address redirects there. The website lists the 0.4.0 features and describes the guest VM.
- The guest kernel identifies itself as dockma's: `uname -r`, `docker info` and `dockma status` show `6.18.57-dockma`, and `/proc/version` names `dockma@dockma.dev` as the builder.

### Fixed
- k3s and k3d clusters work. The server exited seconds after its node became Ready, because the kernel had no VXLAN for flannel. kube-proxy's IPv6 rules failed on every sync, because ip6tables had no `MARK` target. Network policies were silently not enforced, because the kernel had no ipset.
- kind clusters enforce NetworkPolicy. kindnet's policy controller needs nfqueue and conntrack labels, which the kernel lacked.
- iptables-nft in containers has the `REJECT`, `LOG`, `NFLOG`, `CT`, `CONNMARK` and `TCPMSS` targets, the `recent`, `owner` and `set` matches, and, for IPv6, the `MARK` target and `addrtype` match. A rule that used one of these failed to load, and so did the rest of an `iptables-restore` batch that contained it. The kernel also has ipset and VXLAN interfaces, and lists conntrack entries over netlink (`conntrack -L`). This needs the new guest (`dockma install`, or `make guest install-guest`) and `dockma restart`.

## 0.4.0 – 2026-10-17

### Added
- `install.sh` installs the newest release: `curl -fsSL https://maxfrerichs.github.io/dockma/install.sh | sh`. It checks the CLI tarball against the release's `SHA256SUMS`, and against its build provenance attestation when a logged-in `gh` is available. It then fetches the matching guest with the new binary's `dockma install` and installs `dockma` to `~/.local/bin`; a failed guest download leaves the existing installation alone. It installs 0.3.0 or later. `DOCKMA_VERSION`, `DOCKMA_INSTALL_DIR`, `DOCKMA_SKIP_GUEST` and `DOCKMA_RELEASE_URL` adjust it.
- The website shows the install command in its header and in the quick start, next to the build from source.
- The website has search and sharing metadata: canonical URLs, Open Graph and Twitter cards, structured data, a sitemap, `robots.txt`, a favicon and a share image.
- `host.docker.internal` and `gateway.docker.internal` resolve to the Mac in every container, and `--add-host name:host-gateway` points at the Mac instead of the VM. The guest agent serves DNS for containers and relays other names to the DNS servers from the DHCP lease.
- `~/.dockma/daemon.json` is merged over dockerd's configuration at every start, for registry mirrors, insecure registries, proxies, address pools and the like. dockma keeps `hosts`, `group`, `data-root` and `firewall-backend`, and falls back to its own configuration if dockerd rejects the result. `~/.dockma/ca-certificates/*.crt` adds CA certificates (for example a TLS-intercepting proxy's), and `~/.dockma/certs.d/` holds per-registry certificates.
- The kernel has `/dev/net/tun`, for VPN containers such as Tailscale, and xtables over nftables, for the iptables-nft that Docker-in-Docker, kind and k3s run.
- The guest trims the data disk hourly, so `data.img` shrinks on the Mac after images and containers are deleted.
- `dockma status` warns about published ports that a Mac process holds, and the daemon forwards them within 10 s of the port coming free. Before, such a port stayed unforwarded, with only a line in the daemon log, until the container's ports changed.
- `dockma status` shows the daemon's version, and warns when it differs from the CLI's (run `dockma restart` after upgrading).
- `dockma config` warns when `--cpus` exceeds the Mac's cores or `--memory` 75% of its RAM.
- A README section on uninstalling.

### Changed
- **The guest image must be updated** (`dockma install`, or `make guest install-guest` from source, then `dockma restart`). The protocol is unchanged, so an older guest still runs, but without this release's guest-side changes. The agent is 0.6.0.
- Each container's log is capped at three 10 MB files by default (`log-opts`); set your own `log-opts` or `log-driver` in `~/.dockma/daemon.json` to change that.
- Containers get an open-files limit of 1048576 (was 1024 soft, 4096 hard), and `vm.max_map_count` is 262144, which Elasticsearch, OpenSearch and SonarQube need.
- A `DOCKMA_HOME` instance gets a launchd job of its own (`io.dockma.daemon.<hash>`), so it no longer stops or confuses the VM in `~/.dockma`, and it leaves the `dockma` docker context alone. A job an older dockma loaded for that `DOCKMA_HOME` is replaced on the next `start` or `stop`, but only if launchd loaded it from that directory's plist, so a leftover plist can't stop the `~/.dockma` VM. Symlinked paths to one state directory get one job.
- `make e2e` runs against a VM of its own in `~/.dockma-e2e` instead of stopping and restarting yours, and refuses `~/.dockma` unless `E2E_FORCE=1`. `make install-guest` honours `DOCKMA_HOME`.
- `dockma status` and `status --json` report the CPUs and memory the VM actually got, after Virtualization.framework's limits, and warn when they differ from the settings.
- Logs keep three previous generations (`.1` to `.3`) instead of one, so a crash loop doesn't rotate away the first crash.
- `dockma stop` gives the guest 25 s to power off (was 20 s), and the guest gives dockerd 20 s (was 15 s), more than dockerd's own 15 s shutdown with default stop timeouts.
- Config errors name both the `config.json` key and the `dockma config` flag (`memoryMiB (--memory) must be at least 512`), and an unreadable `config.json` names the offending key and suggests deleting the file.

### Fixed
- A guest kernel panic left the VM hung while `dockma status` reported it running. The kernel now reboots after 5 s (`panic=5`), and the VM comes back up in place.
- A DHCP lease renewal removed and re-added the VM's address, dropping the default route and the NAT state of every outgoing container connection. The address is now only replaced when it changes.
- Containers allowed to open vsock sockets (privileged, or with `seccomp=unconfined`) could connect to the agent's ports through vsock loopback and get a root shell in the VM. The kernel has no vsock loopback anymore, and the agent accepts only the host.
- A VM error while stopping made the daemon exit non-zero, so launchd started the VM that `dockma stop` had just stopped.
- A failed write to the daemon log, such as on a full disk, aborted the daemon and hard-stopped the VM.
- `dockma config --disk` accepted a size below the current disk, and the next start failed.
- `dockma stop` could leave the data disk dirty (`recovering journal` on the next boot). The guest stopped waiting for dockerd after about a second, because `pidof dockerd` also matched the init script that runs it, and powered off while dockerd was still stopping containers. It now waits on dockerd itself for up to 20 s, then kills what is left before unmounting.

## 0.3.0 – 2026-10-17

### Added
- `dockma install` downloads the Linux guest (dockma-linux) for its own version from the GitHub release, checks it against the release's `SHA256SUMS` and the guest protocol, and replaces `~/.dockma/guest` atomically. A failed download or check leaves the installed guest alone. `DOCKMA_RELEASE_URL` points it at another directory of release assets.

### Changed
- The guest release asset is now `dockma-linux-<version>-arm64.tar.gz` (was `dockma-guest-<version>.tar.gz`).
- `dockma start` suggests `dockma install` when the guest is missing or speaks another protocol.

## 0.2.0 – 2026-10-17

### Added
- A project website in `site/` (Hugo). It shows the features, the quick start, a `dockma status` sample and the architecture, plus a command reference generated from the docc file. Pinned versions come from `vm/Dockerfile` via `scripts/site-prepare.py`. `make site` builds it, `make site-serve` previews it, and `.github/workflows/pages.yml` deploys it to GitHub Pages.
- Release artifacts. Pushing a version tag drafts a GitHub release with the signed `dockma` binary (`dockma-<version>-macos-arm64.tar.gz`), the guest (`dockma-guest-<version>.tar.gz`, which unpacks into `~/.dockma/guest/`), `SHA256SUMS` and build provenance attestations. The README describes installing from a release.
- CI: `.github/workflows/cli.yml` runs the Swift tests, builds the release binary and checks that the docc reference is current. `.github/workflows/guest.yml` builds the guest, which runs the agent and guest script tests. `make guest` passes extra buildx flags from `BUILDX_FLAGS`.
- `dockma --version` prints the version.

### Changed
- `dockma --help` describes dockma as "Lightweight Docker on macOS", matching the website.

## 0.1.0 – 2026-10-17

### Added
- UDP port forwarding. `docker run -p 1053:53/udp …` answers on `localhost:1053`, over IPv4 and IPv6, and honours `--port-bind-address` as TCP does.
  - Each client gets its own tunnel and source port in the VM. A client's flow ends about 90 s after its last packet, matching docker-proxy.
  - A port tracks up to 256 clients. A new client beyond that ends the least recently active one, so one-shot clients such as DNS lookups are never refused.
  - At most 16 MiB of datagrams wait for the VM per listening address; more are dropped.
- UDP ports below 1024 work with the default `127.0.0.1` bind, like TCP ports: the daemon binds the wildcard address and drops datagrams from non-loopback senders.
- The same port number can be published as both TCP and UDP.
- `dockma status` lists UDP ports with a suffix, for example `ports: 8080, 1053/udp`.

### Changed
- **The guest image must be rebuilt** (`make guest install-guest`, then `dockma restart`). The guest protocol is now 3 and the agent is 0.5.0. This dockma refuses older guest images, and older dockma binaries refuse the new one.

### Known limitations
- With `--port-bind-address 0.0.0.0` on a Mac with several addresses, a UDP reply can leave from a different address than the one the client sent to.
- SCTP ports are not forwarded.
- macOS itself holds some UDP ports, such as 5353 (mDNS). Publish those on another host port.

## 0.0.1 – 2026-10-17

First tagged version. Earlier changes are in the git history.

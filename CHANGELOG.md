# Changelog

All notable changes to dockma are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are git tags without a `v` prefix. Before 1.0, a new feature or an incompatible host↔guest change bumps the minor version, and fixes bump the patch.

## Unreleased

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

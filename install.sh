#!/bin/sh
# Installs the dockma CLI from a GitHub release, then its Linux guest.
#
#   curl -fsSL https://dockma.dev/install.sh | sh
#
# Downloads dockma-<version>-macos-arm64.tar.gz, checks it against the
# release's SHA256SUMS (and its build provenance attestation, when an
# authenticated `gh` is installed), fetches the matching guest with the new
# binary's `dockma install`, then installs the binary. It doesn't start the VM.
#
# Environment:
#   DOCKMA_VERSION       release to install, 0.3.0 or later (default: the latest)
#   DOCKMA_INSTALL_DIR   where the binary goes (default: ~/.local/bin)
#   DOCKMA_SKIP_GUEST=1  install only the CLI, not the guest
#   DOCKMA_RELEASE_URL   directory with the release assets instead of GitHub
#                        (a URL or an absolute path); needs DOCKMA_VERSION. Also
#                        read by `dockma install`.

# Everything is inside main, so a truncated download runs nothing.
main() {
	set -eu

	repo=maxfrerichs/dockma
	install_dir=${DOCKMA_INSTALL_DIR:-$HOME/.local/bin}

	[ "$(uname -s)" = Darwin ] || fail "dockma runs on macOS only."
	# uname -m says x86_64 in a shell running under Rosetta, so ask the hardware.
	[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ] \
		|| fail "dockma needs an Apple Silicon (arm64) Mac."
	macos_major=$(sw_vers -productVersion | cut -d. -f1)
	[ "$macos_major" -ge 14 ] || fail "dockma needs macOS 14 or later."

	if [ -n "${DOCKMA_RELEASE_URL:-}" ]; then
		[ -n "${DOCKMA_VERSION:-}" ] || fail "DOCKMA_RELEASE_URL needs DOCKMA_VERSION."
		version=$DOCKMA_VERSION
		base_url=${DOCKMA_RELEASE_URL%/}
		# A bare absolute path, as `dockma install` accepts it.
		case $base_url in /*) base_url=file://$base_url ;; esac
		protocols=all
	else
		version=${DOCKMA_VERSION:-}
		[ -n "$version" ] || version=$(latest_version) || exit 1
		base_url=https://github.com/$repo/releases/download/$version
		protocols='=https'
	fi
	printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
		|| fail "'$version' is not a dockma version."
	# `dockma install`, which fetches the guest, is new in 0.3.0.
	major=${version%%.*}
	minor=${version#*.}
	minor=${minor%%.*}
	[ "$major" -gt 0 ] || [ "$minor" -ge 3 ] \
		|| fail "this script installs dockma 0.3.0 and later; see the README for $version."

	asset=dockma-$version-macos-arm64.tar.gz
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/dockma-install.XXXXXX")
	trap cleanup EXIT
	trap 'exit 1' HUP INT PIPE TERM

	say "Downloading dockma $version"
	fetch "$base_url/SHA256SUMS" "$tmp/SHA256SUMS"
	fetch "$base_url/$asset" "$tmp/$asset"

	# Only the line for this asset, so the guest's missing file isn't an error.
	grep -E "^[0-9a-f]{64}  $asset\$" "$tmp/SHA256SUMS" > "$tmp/asset.sha256" \
		|| fail "SHA256SUMS has no entry for $asset."
	(cd "$tmp" && shasum -a 256 -c asset.sha256 >/dev/null) \
		|| fail "$asset doesn't match SHA256SUMS."
	say "Checksum verified"
	verify_attestation

	tar -xzf "$tmp/$asset" -C "$tmp" dockma
	actual=$("$tmp/dockma" --version) || fail "the downloaded binary doesn't run."
	[ "$actual" = "$version" ] || fail "the binary reports version '$actual', expected '$version'."

	# The guest first, with the new binary, so a failed download leaves the
	# installed binary and guest as they were.
	if [ "${DOCKMA_SKIP_GUEST:-}" = 1 ]; then
		say "Skipped the guest (DOCKMA_SKIP_GUEST=1); run 'dockma install' later"
	else
		"$tmp/dockma" install < /dev/null || fail "the guest download failed; nothing was installed."
	fi

	# A new inode, moved into place: a running daemon keeps its old binary
	# instead of having its signed pages rewritten underneath it.
	mkdir -p "$install_dir" || fail "can't create $install_dir; set DOCKMA_INSTALL_DIR."
	cp "$tmp/dockma" "$install_dir/.dockma.new.$$" || fail "can't write to $install_dir; set DOCKMA_INSTALL_DIR."
	chmod 0755 "$install_dir/.dockma.new.$$"
	mv -f "$install_dir/.dockma.new.$$" "$install_dir/dockma"
	say "Installed $install_dir/dockma"

	next_steps
}

# Prints the highest version among the published releases. Not
# releases/latest: that skips prereleases, and pre-1.0 releases may be marked
# as such. Drafts aren't listed to anonymous callers.
latest_version() {
	json=$(curl -fsSL --proto '=https' --tlsv1.2 --retry 3 \
		-H 'Accept: application/vnd.github+json' \
		"https://api.github.com/repos/$repo/releases?per_page=100") \
		|| fail "can't reach the GitHub API to look up the latest release (rate limited? set DOCKMA_VERSION)."
	latest=$(printf '%s\n' "$json" \
		| grep -oE '"tag_name": *"[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
		| sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
	[ -n "$latest" ] || fail "no published dockma release found."
	printf '%s\n' "$latest"
}

# Downloads $1 to $2.
fetch() {
	curl -fsSL --proto "$protocols" --tlsv1.2 --retry 3 -o "$2" "$1" \
		|| fail "download failed: $1"
}

# Checks the tarball's build provenance with `gh` when it is installed and
# logged in. A failed check aborts; a missing `gh` only skips it.
verify_attestation() {
	if [ -n "${DOCKMA_RELEASE_URL:-}" ]; then
		return
	fi
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		gh attestation verify "$tmp/$asset" --repo "$repo" >/dev/null \
			|| fail "$asset has no valid build provenance attestation from $repo."
		say "Build provenance verified (gh attestation)"
	else
		say "Skipped the provenance check: needs a logged-in gh (gh attestation verify)"
	fi
}

# Prints what to run next, and warns about PATH, a missing docker CLI and a
# daemon still running the previous binary.
next_steps() {
	found=$(command -v dockma 2>/dev/null || true)
	command=dockma
	[ "$found" = "$install_dir/dockma" ] || command=$install_dir/dockma
	if [ -z "$found" ]; then
		printf '\n%s is not on your PATH. Add it, for example:\n' "$install_dir"
		printf "  echo 'export PATH=\"%s:\$PATH\"' >> ~/.zprofile && exec zsh -l\n" "$install_dir"
	elif [ "$found" != "$install_dir/dockma" ]; then
		printf '\nNote: "dockma" on your PATH is %s, not %s.\n' "$found" "$install_dir/dockma"
	fi

	if ! command -v docker >/dev/null 2>&1; then
		printf '\ndockma provides the engine; you also need the docker CLI:\n  brew install docker\n'
	fi

	# `start` points the launchd job at the binary that runs it.
	running=$(launchctl print "gui/$(id -u)/io.dockma.daemon" 2>/dev/null \
		| sed -n 's/^[[:space:]]*program = //p' | head -n 1)
	if [ -n "$running" ]; then
		printf '\nThe running VM uses %s. Switch it to %s with:\n  %s restart\n' "$running" "$version" "$command"
	else
		printf '\nStart it with:\n  %s start\n  docker context use dockma\n' "$command"
	fi
}

# Removes the files this script downloaded, then the (now empty) temp dir.
cleanup() {
	if [ -n "${tmp:-}" ] && [ -d "$tmp" ]; then
		rm -f "$tmp/SHA256SUMS" "$tmp/asset.sha256" "$tmp/${asset:-}" "$tmp/dockma"
		rmdir "$tmp" 2>/dev/null || true
	fi
	if [ -n "${install_dir:-}" ]; then
		rm -f "$install_dir/.dockma.new.$$"
	fi
}

say() {
	printf '==> %s\n' "$1"
}

fail() {
	printf 'dockma install: %s\n' "$1" >&2
	exit 1
}

main "$@"

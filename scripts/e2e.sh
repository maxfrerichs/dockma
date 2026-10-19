#!/bin/sh
# End-to-end check against a real dockma VM.
# Usage: DOCKMA=<signed binary> [DOCKMA_HOME=<state dir>] scripts/e2e.sh
# Without DOCKMA_HOME it uses ~/.dockma-e2e, a VM of its own with its own
# launchd job, so the user's VM in ~/.dockma keeps running. That VM still
# mounts the real home directory read-write. DOCKER_HOST is pinned to the
# VM's socket so another engine (Lima, Docker Desktop) can't answer instead.
set -eu

DOCKMA=${DOCKMA:-dockma}
DOCKMA_HOME=${DOCKMA_HOME:-$HOME/.dockma-e2e}
export DOCKMA_HOME
DOCKMA_DIR=$DOCKMA_HOME
export DOCKER_HOST="unix://$DOCKMA_DIR/docker.sock"
PORT=18080
UDP_PORT=18053
HELD_PORT=18081
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "--- $*"; }

# The script restarts and stops the VM and writes its daemon.json, so it
# refuses the user's own state directory unless asked.
if [ "$(cd "$DOCKMA_DIR" 2>/dev/null && pwd -P)" = "$(cd "$HOME/.dockma" 2>/dev/null && pwd -P)" ] && [ "${E2E_FORCE:-}" != 1 ]; then
	fail "DOCKMA_HOME is your own ~/.dockma; e2e restarts and stops that VM. Use another directory, or set E2E_FORCE=1"
fi

# A daemon.json that was there before the run is restored, not deleted.
user_daemon_json=
# A failed run leaves nothing behind that would make the next run fail.
cleanup() {
	docker rm -f dockma-e2e-nginx dockma-e2e-echo dockma-e2e-held dockma-e2e-dind dockma-e2e-k3s >/dev/null 2>&1 || true
	docker network rm dockma-e2e-net >/dev/null 2>&1 || true
	docker volume rm dockma-e2e >/dev/null 2>&1 || true
	[ -z "${marker:-}" ] || rm -f -- "$marker"
	[ -z "${holder:-}" ] || kill "$holder" 2>/dev/null || true
	if [ -n "$user_daemon_json" ]; then
		mv "$user_daemon_json" "$DOCKMA_DIR/daemon.json"
	elif [ -n "${wrote_daemon_json:-}" ]; then
		rm -f "$DOCKMA_DIR/daemon.json"
	fi
}
trap cleanup EXIT

if [ ! -f "$DOCKMA_DIR/guest/guest-protocol" ] && [ "$DOCKMA_DIR" != "$HOME/.dockma" ]; then
	[ -f "$HOME/.dockma/guest/guest-protocol" ] ||
		fail "no guest in $DOCKMA_DIR/guest; run: make install-guest DOCKMA_HOME=$DOCKMA_DIR"
	mkdir -p "$DOCKMA_DIR/guest"
	cp "$HOME/.dockma/guest/Image" "$HOME/.dockma/guest/initramfs.cpio.lz4" "$HOME/.dockma/guest/guest-protocol" "$DOCKMA_DIR/guest/"
fi

step "start"
# A VM left running by a failed run would keep its old daemon binary, and
# start would only attach to it.
"$DOCKMA" stop >/dev/null
"$DOCKMA" start >/dev/null
"$DOCKMA" status | grep -q 'state: *running' || fail "status is not running"

step "engine runs in the dockma VM"
docker info --format '{{.Name}} {{.OperatingSystem}}' | grep -q '^dockma dockma VM$' || fail "docker info is not from dockma"

step "hello-world"
docker run --rm hello-world | grep -q 'Hello from Docker!' || fail "hello-world"

step "home directory bind mount at the same path"
marker="$HOME/.dockma-e2e-$$"
docker run --rm -v "$HOME:$HOME" alpine sh -c "echo ok > '$marker'"
[ "$(cat "$marker")" = ok ] || fail "file written in container not visible on host"
rm -f "$marker"

step "stdin half-close (docker run -i)"
[ "$(echo piped | docker run --rm -i alpine cat)" = piped ] || fail "stdin round trip"

step "published port forwarded to localhost"
docker run -d --name dockma-e2e-nginx -p "$PORT:80" nginx:alpine >/dev/null
ok=
for _ in $(seq 1 40); do
	curl -sf -o /dev/null "http://127.0.0.1:$PORT" && ok=1 && break
	sleep 0.25
done
[ -n "$ok" ] || fail "localhost:$PORT not reachable"
docker rm -f dockma-e2e-nginx >/dev/null
sleep 1
curl -sf -m 2 -o /dev/null "http://127.0.0.1:$PORT" && fail "port still forwarded after container removal"

step "published UDP port forwarded to localhost, alongside TCP on the same port"
docker run -d --name dockma-e2e-echo -p "$UDP_PORT:9999/udp" -p "$UDP_PORT:9999/tcp" --entrypoint sh alpine/socat -c \
	'socat TCP-LISTEN:9999,fork,reuseaddr EXEC:cat & exec socat UDP-LISTEN:9999,fork,reuseaddr EXEC:cat' >/dev/null
# echo_check <udp|tcp> <host> <tries>: succeeds once a message comes back.
echo_check() {
	python3 -I - "$@" <<'PY'
import os, socket, sys, time
kind, host, tries = sys.argv[1], sys.argv[2], int(sys.argv[3])
port = int(os.environ["UDP_PORT"])
family = socket.AF_INET6 if ":" in host else socket.AF_INET
for _ in range(tries):
    try:
        if kind == "udp":
            s = socket.socket(family, socket.SOCK_DGRAM)
            s.settimeout(0.5)
            s.sendto(b"ping", (host, port))
            reply = s.recv(64)
        else:
            s = socket.create_connection((host, port), timeout=0.5)
            s.sendall(b"ping")
            reply = s.recv(64)
        if reply == b"ping":
            sys.exit(0)
    except OSError:
        time.sleep(0.25)
sys.exit(1)
PY
}
export UDP_PORT
echo_check udp 127.0.0.1 40 || fail "udp 127.0.0.1:$UDP_PORT not answering"
echo_check udp ::1 4 || fail "udp [::1]:$UDP_PORT not answering"
echo_check tcp 127.0.0.1 4 || fail "tcp 127.0.0.1:$UDP_PORT not answering next to udp"
"$DOCKMA" status | grep -q "$UDP_PORT/udp" || fail "status does not list $UDP_PORT/udp"
docker rm -f dockma-e2e-echo >/dev/null
sleep 1
# A leaked relay looks like a closed port (the agent's send is refused), so
# check the daemon's view too.
"$DOCKMA" status | grep -q "$UDP_PORT/udp" && fail "status still lists $UDP_PORT/udp after container removal"
echo_check udp 127.0.0.1 2 && fail "udp port still forwarded after container removal"

step "a port held on the Mac is reported, then forwarded once free"
python3 -I -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(600)' "$HELD_PORT" &
holder=$!
sleep 0.5
docker run -d --name dockma-e2e-held -p "$HELD_PORT:80" nginx:alpine >/dev/null
ok=
for _ in $(seq 1 20); do
	"$DOCKMA" status | grep -q "port $HELD_PORT is" && ok=1 && break
	sleep 0.25
done
[ -n "$ok" ] || fail "status does not report the held port $HELD_PORT"
kill "$holder"
holder=
ok=
for _ in $(seq 1 60); do
	curl -sf -m 2 -o /dev/null "http://127.0.0.1:$HELD_PORT" && ok=1 && break
	sleep 0.5
done
[ -n "$ok" ] || fail "port $HELD_PORT not forwarded after the Mac process let go of it"
"$DOCKMA" status | grep -q "port $HELD_PORT is" && fail "status still reports port $HELD_PORT"
docker rm -f dockma-e2e-held >/dev/null

step "host.docker.internal resolves to the Mac, on the default bridge and other networks"
gateway=$("$DOCKMA" shell -- cat /run/dockma/gateway)
[ -n "$gateway" ] || fail "no gateway recorded in the guest"
resolved=$(docker run --rm alpine sh -c 'nslookup host.docker.internal | awk "/^Address: / {print \$2}"')
[ "$resolved" = "$gateway" ] || fail "host.docker.internal is '$resolved', want $gateway"
docker network create dockma-e2e-net >/dev/null
resolved=$(docker run --rm --network dockma-e2e-net alpine sh -c 'nslookup host.docker.internal | awk "/^Address: / {print \$2}"')
docker network rm dockma-e2e-net >/dev/null
[ "$resolved" = "$gateway" ] || fail "host.docker.internal on a user network is '$resolved', want $gateway"
docker run --rm --add-host=hg:host-gateway alpine grep -q "${gateway}[[:space:]]*hg" /etc/hosts ||
	fail "host-gateway is not the Mac"
docker run --rm alpine nslookup example.com >/dev/null || fail "other names no longer resolve"
# The forwarder sits behind a redirect, so port 53 stays free for containers.
docker run --rm -p 53:53/udp -p 53:53/tcp alpine true || fail "publishing port 53 failed"
docker run --rm --network host python:3-alpine python -c '
import socket
for kind in (socket.SOCK_DGRAM, socket.SOCK_STREAM):
    socket.socket(socket.AF_INET, kind).bind(("0.0.0.0", 53))
' || fail "binding port 53 with --network host failed"

step "limits: open files, vm.max_map_count, /dev/net/tun"
[ "$(docker run --rm alpine sh -c 'ulimit -n')" = 1048576 ] || fail "container ulimit -n"
[ "$("$DOCKMA" shell -- cat /proc/sys/vm/max_map_count)" = 262144 ] || fail "vm.max_map_count"
"$DOCKMA" shell -- test -c /dev/net/tun || fail "no /dev/net/tun"

step "containers get log rotation by default"
created=$(docker create alpine true)
max_size=$(docker inspect --format '{{index .HostConfig.LogConfig.Config "max-size"}}' "$created")
docker rm "$created" >/dev/null
[ "$max_size" = 10m ] || fail "default log max-size is '$max_size', want 10m"

step "vsock: containers can't reach the agent, even without seccomp"
docker run --rm --security-opt seccomp=unconfined python:3-alpine python -c '
import socket, sys
# 1: vsock loopback, 3: the VM itself. Refused, reset or closed at once is
# isolated; a connection the shell port keeps open is the agent answering.
for cid in (1, 3):
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect((cid, 1027))
        if s.recv(1) == b"":
            continue
    except TimeoutError:
        sys.exit(f"CID {cid}: the agent accepted the connection and kept it")
    except OSError:
        continue
    sys.exit(f"CID {cid}: the agent answered")
' || fail "a container reached the agent's shell port"

step "Docker-in-Docker starts its engine (iptables-nft in the inner dockerd)"
docker run -d --privileged --name dockma-e2e-dind docker:dind >/dev/null
ok=
for _ in $(seq 1 60); do
	docker exec dockma-e2e-dind docker info >/dev/null 2>&1 && ok=1 && break
	sleep 1
done
[ -n "$ok" ] || { docker logs --tail 20 dockma-e2e-dind >&2; fail "dockerd in docker:dind did not start"; }
docker rm -f dockma-e2e-dind >/dev/null

# The kernel has no modules, so a missing option shows up only when a
# workload asks for it. These are the ones kube-proxy, k3s and CNIs use,
# checked in both address families; each failure names its feature.
step "kernel features for iptables-nft, ipset and VXLAN in containers"
docker run --rm -i --privileged alpine sh <<'EOF' || fail "kernel features missing (see above)"
apk add -q iptables ip6tables ipset iproute2 nftables conntrack-tools >/dev/null || exit 1
failed=0
check() {
	name=$1
	shift
	out=$("$@" 2>&1) || { echo "missing: $name: $(echo "$out" | tail -n 1)"; failed=1; }
}
for f in iptables ip6tables; do
	check "$f REJECT" xtables-nft-multi $f -A INPUT -p tcp --dport 9 -j REJECT
	check "$f MARK" xtables-nft-multi $f -t nat -A POSTROUTING -j MARK --xor-mark 0x4000
	check "$f addrtype" xtables-nft-multi $f -A INPUT -m addrtype --dst-type LOCAL -j ACCEPT
	check "$f recent" xtables-nft-multi $f -A INPUT -m recent --name e2e --set
	check "$f NFLOG" xtables-nft-multi $f -A INPUT -j NFLOG
	check "$f LOG" xtables-nft-multi $f -A INPUT -j LOG
	check "$f CT" xtables-nft-multi $f -t raw -A PREROUTING -j CT --notrack
	check "$f CONNMARK" xtables-nft-multi $f -t mangle -A PREROUTING -j CONNMARK --restore-mark
	check "$f TCPMSS" xtables-nft-multi $f -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
	check "$f owner" xtables-nft-multi $f -A OUTPUT -m owner --uid-owner 0 -j ACCEPT
done
check "ipset hash:ip" ipset create e2e-ip hash:ip
check "ipset hash:net" ipset create e2e-net hash:net
check "ipset list:set" ipset create e2e-list list:set
check "iptables set match" xtables-nft-multi iptables -A INPUT -m set --match-set e2e-ip src -j ACCEPT
# kind's network policy: connections queued to userspace, accepted ones
# labeled in conntrack, conntrack entries listed over netlink.
nft add table inet e2e && nft add chain inet e2e c '{ type filter hook forward priority 0; }'
check "nft queue" nft add rule inet e2e c queue num 100 bypass
check "nft ct label" nft add rule inet e2e c ct label set 100
check "conntrack netlink" conntrack -L
check "vxlan" ip link add e2e-vx type vxlan id 42 dstport 4789 dev eth0
check "/proc/config.gz" test -s /proc/config.gz
exit $failed
EOF

# k3s (what k3d runs) uses VXLAN for flannel, ipset for network policy and
# iptables-nft for kube-proxy. Each degrades on its own: flannel's failure
# stops the server seconds after the node is Ready, the others only log.
step "k3s server stays up, kube-proxy syncs, the network policy controller starts"
docker run -d --privileged --name dockma-e2e-k3s --tmpfs /run --tmpfs /var/run \
	rancher/k3s:v1.33.5-k3s1 server --disable=traefik,metrics-server >/dev/null
ok=
for _ in $(seq 1 90); do
	[ "$(docker exec dockma-e2e-k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')" = Ready ] && ok=1 && break
	sleep 1
done
[ -n "$ok" ] || { docker logs --tail 20 dockma-e2e-k3s >&2; fail "k3s node not Ready"; }
# A Service without endpoints makes kube-proxy write a REJECT rule.
docker exec dockma-e2e-k3s kubectl create service clusterip dockma-e2e-noep --tcp=80 >/dev/null || fail "k3s: create service"
sleep 20
[ "$(docker inspect -f '{{.State.Running}}' dockma-e2e-k3s)" = true ] || { docker logs --tail 20 dockma-e2e-k3s >&2; fail "k3s server exited"; }
k3s_log=$(docker logs dockma-e2e-k3s 2>&1)
for problem in "Failed to execute iptables-restore" "Skipping network policy controller" "flannel exited"; do
	if printf '%s\n' "$k3s_log" | grep -qF "$problem"; then
		printf '%s\n' "$k3s_log" | grep -F -A 4 "$problem" | head -n 10 >&2
		fail "k3s: $problem"
	fi
done
docker rm -f dockma-e2e-k3s >/dev/null

step "amd64 image via Rosetta"
[ "$(docker run --rm --platform linux/amd64 alpine uname -m)" = x86_64 ] || fail "amd64 container"

step "logs"
[ -n "$("$DOCKMA" logs -n 5)" ] || fail "console log empty"
[ -n "$("$DOCKMA" logs --docker -n 5)" ] || fail "docker log empty"

step "shell: command, exit code, stdin, stderr"
[ "$("$DOCKMA" shell -- uname -r)" = "$(docker info --format '{{.KernelVersion}}')" ] || fail "shell uname"
set +e
"$DOCKMA" shell -- sh -c 'exit 7'
code=$?
set -e
[ "$code" = 7 ] || fail "shell exit code: got $code, want 7"
[ "$(echo hi | "$DOCKMA" shell -- cat)" = hi ] || fail "shell stdin"
[ -z "$("$DOCKMA" shell -- sh -c 'echo e >&2' 2>/dev/null)" ] || fail "shell stderr leaked into stdout"

step "shell: interactive PTY (resize, Ctrl-C, exit code)"
python3 - "$DOCKMA" <<'PY' || fail "interactive shell"
import os, pty, re, select, signal, struct, sys, termios, fcntl, time
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], "shell"])
buf = b""
def expect(pattern, timeout=10):
    global buf
    end = time.time() + timeout
    while time.time() < end:
        if select.select([fd], [], [], 0.2)[0]:
            buf += os.read(fd, 4096)
        m = re.search(pattern, buf)
        if m:
            buf = buf[m.end():]
            return m
    sys.exit(f"timed out waiting for {pattern!r}, got {buf[-200:]!r}")
expect(rb"Linux \d+\.\d+")  # the motd's status line
expect(rb"dockma:~# ")
os.write(fd, b"tty\n"); expect(rb"/dev/pts/\d+"); expect(rb"dockma:~# ")
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0)); os.kill(pid, signal.SIGWINCH); time.sleep(0.5)
os.write(fd, b"stty size\n"); expect(rb"\r\n40 120\r\n"); expect(rb"dockma:~# ")
os.write(fd, b"sleep 30\n"); time.sleep(1); os.write(fd, b"\x03"); expect(rb"dockma:~# ", 5)
os.write(fd, b"echo rc=$?\n"); expect(rb"rc=130\r\n")
os.write(fd, b"exit 4\n")
code = os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])
sys.exit(0 if code == 4 else f"exit code {code}, want 4")
PY

step "shell works while dockerd is unresponsive"
"$DOCKMA" shell -- sh -c 'kill -STOP $(pidof dockerd)'
[ "$("$DOCKMA" shell -- echo alive)" = alive ] || fail "shell with frozen dockerd"
"$DOCKMA" shell -- sh -c 'kill -CONT $(pidof dockerd)'
docker info >/dev/null 2>&1 || fail "dockerd did not resume"

step "300 concurrent docker.sock connections (launchd's default limit is 256 fds)"
python3 - "$DOCKMA_DIR/docker.sock" <<'PY' || fail "daemon did not cope with 300 open connections"
import socket, subprocess, sys, time
conns = []
for _ in range(300):
    # A sub-millisecond burst can overrun the listen backlog (somaxconn,
    # 128) before the accept loop runs; that's not what this step tests.
    for attempt in range(50):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(sys.argv[1])
            break
        except ConnectionRefusedError:
            s.close()
            time.sleep(0.01)
    else:
        sys.exit("connect kept being refused")
    s.sendall(b"GET /_ping HTTP/1.1\r\nHost: docker\r\n")  # incomplete: held open
    conns.append(s)
if subprocess.run(["docker", "info", "--format", "{{.Name}}"], capture_output=True, timeout=30).returncode != 0:
    sys.exit("docker info failed while 300 connections were open")
# Every held connection must have been accepted and proxied, not shed.
for s in conns:
    s.settimeout(10)
    s.sendall(b"Connection: close\r\n\r\n")
    if not s.recv(64).startswith(b"HTTP/1.1 200"):
        sys.exit("a held connection did not answer /_ping")
    s.close()
PY

step "restart keeps data and applies daemon.json; registry pulls work afterwards"
docker volume create dockma-e2e >/dev/null
docker run --rm -v dockma-e2e:/data alpine sh -c 'echo persisted > /data/f'
# A protected key is ignored; the rest applies.
if [ -e "$DOCKMA_DIR/daemon.json" ]; then
	user_daemon_json="$DOCKMA_DIR/daemon.json.e2e-saved"
	mv "$DOCKMA_DIR/daemon.json" "$user_daemon_json"
fi
wrote_daemon_json=1
printf '{"registry-mirrors": ["https://mirror.dockma-e2e.invalid"], "data-root": "/elsewhere"}\n' >"$DOCKMA_DIR/daemon.json"
"$DOCKMA" restart >/dev/null
docker info --format '{{.RegistryConfig.Mirrors}}' | grep -q 'mirror.dockma-e2e.invalid' || fail "daemon.json mirror not applied"
[ "$(docker info --format '{{.DockerRootDir}}')" = /var/lib/docker ] || fail "daemon.json changed data-root"
[ "$(docker run --rm -v dockma-e2e:/data alpine cat /data/f)" = persisted ] || fail "volume data lost across restart"
docker volume rm dockma-e2e >/dev/null
docker pull -q busybox >/dev/null || fail "registry pull over HTTPS"

step "stop"
"$DOCKMA" stop >/dev/null
"$DOCKMA" status | grep -q 'stopped' || fail "status after stop"
for plist in "$DOCKMA_DIR"/io.dockma.daemon*.plist "$HOME"/Library/LaunchAgents/io.dockma.daemon*.plist; do
	[ -e "$plist" ] || continue
	# Only this state directory's job; the user's own may well be running.
	plutil -extract EnvironmentVariables.DOCKMA_HOME raw "$plist" 2>/dev/null | grep -qxF "$DOCKMA_HOME" || continue
	label=$(plutil -extract Label raw "$plist")
	launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && fail "launchd job $label still loaded"
done
tail -n 1 "$DOCKMA_DIR/logs/daemon.log" | grep -q 'VM stopped' || fail "last daemon log line is not a graceful stop"

echo "all e2e checks passed"

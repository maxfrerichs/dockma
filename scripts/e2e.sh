#!/bin/sh
# End-to-end check against a real dockma VM. Usage: DOCKMA=<signed binary> scripts/e2e.sh
# DOCKER_HOST is pinned to dockma's socket so another engine (Lima, Docker
# Desktop) can't answer instead.
set -eu

DOCKMA=${DOCKMA:-dockma}
DOCKMA_DIR=${DOCKMA_HOME:-$HOME/.dockma}
export DOCKER_HOST="unix://$DOCKMA_DIR/docker.sock"
PORT=18080
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "--- $*"; }

cleanup() { docker rm -f dockma-e2e-nginx >/dev/null 2>&1 || true; }
trap cleanup EXIT

step "start"
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
expect(rb"kernel \d+\.\d+")  # the motd's status line
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

step "restart keeps data; registry pulls work afterwards"
docker volume create dockma-e2e >/dev/null
docker run --rm -v dockma-e2e:/data alpine sh -c 'echo persisted > /data/f'
"$DOCKMA" restart >/dev/null
[ "$(docker run --rm -v dockma-e2e:/data alpine cat /data/f)" = persisted ] || fail "volume data lost across restart"
docker volume rm dockma-e2e >/dev/null
docker pull -q busybox >/dev/null || fail "registry pull over HTTPS"

step "stop"
"$DOCKMA" stop >/dev/null
"$DOCKMA" status | grep -q 'stopped' || fail "status after stop"
launchctl print "gui/$(id -u)/io.dockma.daemon" >/dev/null 2>&1 && fail "launchd job still loaded"
tail -n 1 "$DOCKMA_DIR/logs/daemon.log" | grep -q 'VM stopped' || fail "last daemon log line is not a graceful stop"

echo "all e2e checks passed"

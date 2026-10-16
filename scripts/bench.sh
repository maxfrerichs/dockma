#!/bin/sh
# Boot and network benchmark against a real dockma VM. Restarts the VM RUNS
# times, so it is not part of e2e. Usage: DOCKMA=<binary> RUNS=5 scripts/bench.sh
# RUNS=0 skips the boot part and benchmarks the running VM's network only.
# DOCKER_HOST is pinned to dockma's socket so another engine (Lima, Docker
# Desktop) can't answer instead.
set -eu

DOCKMA=${DOCKMA:-dockma}
DOCKMA_DIR=${DOCKMA_HOME:-$HOME/.dockma}
RUNS=${RUNS:-5}
export DOCKER_HOST="unix://$DOCKMA_DIR/docker.sock"
PORT=18081
IMAGE=dockma-bench
step() { echo "--- $*"; }

cleanup() { docker rm -f dockma-bench-iperf dockma-bench-http >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [ "$RUNS" -gt 0 ]; then
step "boot ($RUNS runs)"
python3 - "$DOCKMA" "$DOCKMA_DIR" "$RUNS" <<'PY'
import os, re, socket, statistics, subprocess, sys, time

dockma, state, runs = sys.argv[1], sys.argv[2], int(sys.argv[3])
sock = os.path.join(state, "docker.sock")

def docker_ready():
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            s.connect(sock)
            s.sendall(b"GET /_ping HTTP/1.0\r\nHost: docker\r\n\r\n")
            return b" 200 " in s.recv(4096).split(b"\r\n", 1)[0]
    except OSError:
        return False

def shell(*argv):
    return subprocess.run([dockma, "shell", "--", *argv], check=True, capture_output=True, text=True).stdout

ready, returned = [], []
for i in range(runs):
    subprocess.run([dockma, "stop"], check=True, capture_output=True)
    t0 = time.monotonic()
    start = subprocess.Popen([dockma, "start"], stdout=subprocess.DEVNULL)
    while not docker_ready():
        if time.monotonic() - t0 > 60:
            sys.exit("Docker did not answer within 60 s")
        time.sleep(0.01)
    t_ready = time.monotonic()
    if start.wait() != 0:
        sys.exit("dockma start failed")
    t_returned = time.monotonic()
    ready.append(t_ready - t0)
    returned.append(t_returned - t0)
    print(f"run {i + 1}: docker ready {ready[-1] * 1000:.0f} ms, dockma start returned {returned[-1] * 1000:.0f} ms")

def summary(name, xs):
    print(f"{name}: median {statistics.median(xs) * 1000:.0f} ms, max {max(xs) * 1000:.0f} ms")

summary("docker ready", ready)
summary("dockma start returned", returned)

# Phase breakdown of the last run. Guest uptime is read through the shell and
# moved back to the moment Docker answered.
before = time.monotonic()
uptime = float(shell("cat", "/proc/uptime").split()[0])
after = time.monotonic()
uptime_at_ready = uptime - ((before + after) / 2 - t_ready)
dmesg = shell("dmesg")
console = open(os.path.join(state, "logs", "console.log"), errors="replace").read()
docker_log = open(os.path.join(state, "logs", "docker.log"), errors="replace").read()

def dmesg_time(text):
    m = re.search(r"^\[\s*([\d.]+)\] .*" + re.escape(text), dmesg, re.M)
    return float(m.group(1)) if m else None

def docker_time(text):
    # The log holds earlier boots too; the last match is this boot's.
    times = re.findall(r'time="[^"]*T\d\d:(\d\d):([\d.]+)Z" level=\w+ msg="' + re.escape(text), docker_log)
    if not times:
        return None
    minutes, seconds = times[-1]
    return int(minutes) * 60 + float(seconds)

marks = [(float(t), name) for t, name in re.findall(r"^dockma: \[([\d.]+)\] (.+?)\r?$", console, re.M)]
run_init = dmesg_time("Run /init as init process")
unpack_start = dmesg_time("Unpacking initramfs")
unpack_end = dmesg_time("Freeing initrd memory")
dockerd_start, dockerd_ready = docker_time("Starting up"), docker_time("API listen")

def row(name, seconds):
    print(f"  {name:<28} {'?' if seconds is None else f'{seconds * 1000:6.0f} ms'}")

print(f"phases of run {runs}:")
row("host: CLI, launchd, VZ", ready[-1] - uptime_at_ready)
row("kernel up to stage 0", run_init)
row("initramfs unpack", unpack_end - unpack_start if unpack_start is not None and unpack_end is not None else None)
previous, previous_name = run_init, "stage 0"
for t, name in marks:
    row(f"{previous_name} -> {name}", t - previous if previous is not None else None)
    previous, previous_name = t, name
row("dockerd", dockerd_ready - dockerd_start if dockerd_start is not None and dockerd_ready is not None else None)
row("CLI overhead", returned[-1] - ready[-1])
PY
fi

step "network: bench image"
docker build -q -t "$IMAGE" - >/dev/null <<'EOF'
FROM alpine:3.24
RUN apk add --no-cache iperf3 busybox-extras
EOF

step "network: container to container over the bridge (iperf3, 10 s)"
docker run -d --name dockma-bench-iperf "$IMAGE" iperf3 -s >/dev/null
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dockma-bench-iperf)
sleep 1
docker run --rm "$IMAGE" iperf3 -c "$ip" -t 10 -J |
	python3 -c 'import json, sys; print("  %.2f Gbit/s" % (json.load(sys.stdin)["end"]["sum_received"]["bits_per_second"] / 1e9))'

step "network: published port to macOS (1 GiB over HTTP, 3 runs)"
docker run -d --name dockma-bench-http --tmpfs /w:size=1100m -p "$PORT:8080" "$IMAGE" \
	sh -c 'head -c 1073741824 /dev/zero >/w/blob && exec httpd -f -p 8080 -h /w' >/dev/null
for _ in $(seq 1 100); do
	curl -sfI -o /dev/null "http://127.0.0.1:$PORT/blob" && break
	sleep 0.2
done
for _ in 1 2 3; do
	curl -sf -o /dev/null -w '%{speed_download}\n' "http://127.0.0.1:$PORT/blob"
done | python3 -c 'import statistics, sys; print("  median %.2f Gbit/s" % (statistics.median(float(l) for l in sys.stdin) * 8 / 1e9))'

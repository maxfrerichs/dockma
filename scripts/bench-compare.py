#!/usr/bin/env python3
"""Benchmarks dockma against Lima and OrbStack with equal resources.

Usage (DOCKMA=<binary> benchmarks another dockma build; ~/.dockma keeps the installed one):
  scripts/bench-compare.py --prepare            # once, needs network and one running engine
  scripts/bench-compare.py [--engines dockma,lima,orbstack] [--suites ...] [--rounds 6]

Only one engine runs at a time; daily engines (~/.dockma, other Lima
instances, OrbStack when not benchmarked) are stopped first and restored at
exit. Round 1 is a warm-up and is kept in raw.jsonl but marked. The method
and instance setup are in docs/benchmarks.md; scripts/bench-report.py
summarizes a results directory.
"""
import argparse
import json
import os
import platform
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tarfile
import time
from pathlib import Path

HOME = Path.home()
WORK = HOME / "dockma-bench-work.noindex"
CACHE = WORK / "cache"
FIXTURES = Path(__file__).resolve().parent / "bench-fixtures"
TOOLS = "dockma-bench-tools"
IMAGES = [TOOLS, "node:22-alpine", "postgres:17-alpine", "redis:8-alpine"]
GIT_URL = "https://www.kernel.org/pub/software/scm/git/git-2.50.0.tar.xz"
GIT_SHA256 = "dff3c000e400ace3a63b8a6f8b3b76b88ecfdffd4504a04aba4248372cdec045"
GIT_DIR = "git-2.50.0"
SUITES = ["boot", "idle", "disk", "mount", "network", "workload"]
PORT = 18081
DOCKMA = os.environ.get("DOCKMA", "dockma")  # e.g. a branch's .build/debug/dockma


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def run(argv, env=None, check=True, capture=True, timeout=None, stdin=None):
    """Runs argv and returns its stdout."""
    r = subprocess.run(argv, env=env, check=False, timeout=timeout, stdin=stdin,
                       stdout=subprocess.PIPE if capture else None, stderr=subprocess.PIPE if capture else None,
                       text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, argv))} failed ({r.returncode}): {(r.stderr or '').strip()[-2000:]}")
    return r.stdout or ""


def ping(sock):
    """Whether a Docker API answers /_ping on the unix socket."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            s.connect(str(sock))
            s.sendall(b"GET /_ping HTTP/1.0\r\nHost: docker\r\n\r\n")
            return b" 200 " in s.recv(4096).split(b"\r\n", 1)[0]
    except OSError:
        return False


def wait_for(predicate, timeout, what):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise RuntimeError(f"timed out waiting for {what}")
        time.sleep(0.01)


def safe_rmtree(path):
    """Deletes a directory, but only below the bench work dir."""
    path = Path(path).resolve()
    if not str(path).startswith(str(WORK.resolve()) + "/"):
        raise RuntimeError(f"refusing to delete {path}: not below {WORK}")
    if path.exists():
        shutil.rmtree(path)


class Engine:
    name = ""
    host_gateway = "host-gateway"

    def env(self):
        return {**os.environ, "DOCKER_HOST": f"unix://{self.socket}"}

    def docker(self, *argv, **kw):
        return run(["docker", *argv], env=self.env(), **kw)

    def is_up(self):
        return ping(self.socket)

    def stop(self):
        if self.is_up():
            self._stop()
        wait_for(lambda: not self.is_up(), 60, f"{self.name} to stop")

    def assert_identity(self):
        """Aborts unless the socket's engine is this one, so prune never hits another engine."""
        info = self.docker("info", "--format", "{{.Name}}|{{.OperatingSystem}}|{{.Labels}}").strip()
        if not self.identity(info):
            raise RuntimeError(f"{self.socket} answered as {info!r}, not {self.name}; refusing to continue")

    def host_pids(self):
        """The engine's host processes; VZ processes count because only one engine runs."""
        pids = run(["pgrep", "-f", "com.apple.Virtualization.VirtualMachine"], check=False).split()
        for pattern in self.process_patterns:
            pids += run(["pgrep", "-f", pattern], check=False).split()
        return sorted(set(int(p) for p in pids))


class Dockma(Engine):
    name = "dockma"
    process_patterns = ["dockma daemon"]

    def __init__(self, home=HOME / ".dockma-bench", binary=DOCKMA):
        self.home = home
        self.binary = binary
        self.socket = home / "docker.sock"

    def dockma_env(self):
        return {**os.environ, "DOCKMA_HOME": str(self.home)}

    def check(self):
        if not (self.home / "guest").is_dir():
            return f"no guest in {self.home}: see Setup in docs/benchmarks.md"
        daemon_json = self.home / "daemon.json"
        if not daemon_json.exists() or "dockma.bench=1" not in daemon_json.read_text(errors="replace"):
            return f"{self.home}/daemon.json lacks the dockma-bench label that tells this VM from ~/.dockma: see Setup in docs/benchmarks.md"

    def start_argv(self):
        return [self.binary, "start"]

    def start(self):
        run(self.start_argv(), env=self.dockma_env())

    def _stop(self):
        run([self.binary, "stop"], env=self.dockma_env())

    def identity(self, info):
        return info == "dockma|dockma VM|[dockma.bench=1]"

    def config(self):
        guest = self.home / "guest"
        return (run([self.binary, "config"], env=self.dockma_env(), check=False) + run([self.binary, "--version"], check=False)
                + run(["shasum", "-a", "256", str(guest / "dockma-kernel"), str(guest / "dockma-initrd.img"), str(guest / "guest-protocol")], check=False))


class Lima(Engine):
    name = "lima"
    instance = "bench"
    host_gateway = "192.168.5.2"
    process_patterns = ["limactl", "lima-driver"]

    def __init__(self):
        self.socket = HOME / ".lima" / self.instance / "sock" / "docker.sock"

    def check(self):
        if not shutil.which("limactl") or self.instance not in run(["limactl", "list", "-q"], check=False).split():
            return ("no Lima instance 'bench': limactl create --name=bench --cpus=4 --memory=4 --vm-type=vz "
                    "--mount-type=virtiofs --mount-writable template://docker-rootful")

    def start_argv(self):
        return ["limactl", "start", self.instance]

    def start(self):
        run(self.start_argv())

    def _stop(self):
        run(["limactl", "stop", self.instance])

    def identity(self, info):
        return info.startswith(f"lima-{self.instance}|Ubuntu")

    def config(self):
        return run(["limactl", "list", self.instance, "--format", "json"], check=False) + run(["limactl", "--version"], check=False)


class OrbStack(Engine):
    name = "orbstack"
    process_patterns = ["OrbStack.app"]

    def __init__(self):
        self.socket = HOME / ".orbstack" / "run" / "docker.sock"

    def check(self):
        if not shutil.which("orb"):
            return "OrbStack is not installed; install it, then orb config set cpu 4 and orb config set memory_mib 4096"

    def start_argv(self):
        return ["orb", "start"]

    def start(self):
        run(self.start_argv())
        wait_for(self.is_up, 120, "OrbStack's docker")

    def _stop(self):
        run(["orb", "stop"])

    def identity(self, info):
        return "|OrbStack|" in info

    def config(self):
        return run(["orb", "config", "show"], check=False) + run(["orb", "version"], check=False)


ENGINES = {"dockma": Dockma, "lima": Lima, "orbstack": OrbStack}


class Recorder:
    def __init__(self, out):
        self.file = open(out / "raw.jsonl", "a")
        self.round = 0

    def __call__(self, engine, suite, metric, value, unit, better):
        rec = dict(engine=engine.name, suite=suite, metric=metric, value=value, unit=unit, better=better,
                   round=self.round, warmup=self.round == 0)
        self.file.write(json.dumps(rec) + "\n")
        self.file.flush()
        log(f"  {engine.name:<8} {suite}/{metric}: {'–' if value is None else f'{value:.3f}'} {unit}")


def in_container_times(engine, script, *docker_args):
    """Runs a shell script in the tools image; `t NAME CMD...` lines in it print NAME and the seconds CMD took."""
    helper = ('now() { cut -d" " -f1 /proc/uptime; }\n'
              't() { n=$1; shift; s=$(now); "$@" >/dev/null; e=$(now); echo "$n $(echo "$e $s" | awk \'{print $1-$2}\')"; }\n'
              'drop() { sync; echo 3 >/proc/sys/vm/drop_caches; }\n')
    out = engine.docker("run", "--rm", "--privileged", *docker_args, TOOLS, "sh", "-ec", helper + script)
    return [(name, float(seconds)) for name, seconds in (l.rsplit(" ", 1) for l in out.splitlines())]


def fio(engine, *docker_args, **params):
    argv = ["fio", "--name=b", "--output-format=json"] + [f"--{k}={v}" for k, v in params.items()]
    job = json.loads(engine.docker("run", "--rm", *docker_args, TOOLS, *argv))["jobs"][0]
    return job["read"] if "read" in params["rw"] else job["write"]


def suite_boot(engine, rec, args):
    for _ in range(args.boot_runs):
        engine.stop()
        t0 = time.monotonic()
        start = subprocess.Popen(engine.start_argv(), env=getattr(engine, "dockma_env", engine.env)(),
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(engine.is_up, 180, f"{engine.name} docker")
        t_ready = time.monotonic()
        if start.wait() != 0:
            raise RuntimeError(f"{engine.name} start failed")
        rec(engine, "boot", "stop→docker ready", t_ready - t0, "s", "lower")
        rec(engine, "boot", "stop→start command returned", time.monotonic() - t0, "s", "lower")


def footprint(engine):
    """Summed phys_footprint (MiB) and CPU seconds of the engine's host processes."""
    mib, cpu = 0.0, 0.0
    for pid in engine.host_pids():
        out = run(["footprint", "-p", str(pid)], check=False)
        if m := re.search(r"phys_footprint:\s+([\d.]+)\s+(KB|MB|GB)", out):
            mib += float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)]
        t = run(["ps", "-o", "time=", "-p", str(pid)], check=False).strip()
        if t:
            parts = [float(x) for x in re.split(r"[:]", t)]
            cpu += sum(x * 60 ** i for i, x in enumerate(reversed(parts)))
    return mib, cpu


def suite_idle(engine, rec, args):
    time.sleep(args.idle_settle)
    mib0, cpu0 = footprint(engine)
    time.sleep(args.idle_sample)
    mib1, cpu1 = footprint(engine)
    rec(engine, "idle", "host memory footprint", (mib0 + mib1) / 2, "MiB", "lower")
    rec(engine, "idle", "host CPU", (cpu1 - cpu0) / args.idle_sample * 100, "% of a core", "lower")


def suite_disk(engine, rec, args):
    w = fio(engine, directory="/tmp", rw="write", bs="1m", size="1g", end_fsync=1)
    rec(engine, "disk", "container fs seq write 1 GiB", w["bw_bytes"] / 1e6, "MB/s", "higher")
    w = fio(engine, directory="/tmp", rw="randwrite", bs="4k", size="256m", fsync=1, runtime=20, time_based=1)
    rec(engine, "disk", "container fs 4k randwrite + fsync", w["iops"], "IOPS", "higher")


def suite_mount(engine, rec, args):
    base = WORK / "mount" / engine.name
    safe_rmtree(base)
    base.mkdir(parents=True)
    vol = ["-v", f"{base}:/w", "-v", f"{CACHE}:/cache:ro"]
    times = in_container_times(engine, f"""
        t "extract {GIT_DIR}.tar" tar xf /cache/{GIT_DIR}.tar -C /w
        cd /w/{GIT_DIR}
        git config --global user.email b@b; git config --global user.name b; git config --global --add safe.directory '*'
        t "git init+add+commit" sh -c 'git init -q && git add -A && git commit -qm x'
        drop; t "git status (guest cache cold)" git status
        t "git status (warm)" git status
        drop; t "find -type f (guest cache cold)" find /w -type f
        """, *vol)
    for metric, seconds in times:
        rec(engine, "mount", metric, seconds, "s", "lower")

    npm = base / "npm"
    npm.mkdir()
    for f in ("package.json", "package-lock.json"):
        shutil.copy(FIXTURES / "npm" / f, npm)
    engine.docker("volume", "rm", "-f", "dockma-bench-npm")
    engine.docker("run", "--rm", "-v", f"{CACHE}/npm:/seed:ro", "-v", "dockma-bench-npm:/npm", TOOLS, "cp", "-a", "/seed/.", "/npm/")
    out = engine.docker("run", "--rm", "-v", f"{npm}:/p", "-v", "dockma-bench-npm:/npm", "-w", "/p", "node:22-alpine", "sh", "-ec",
                        's=$(cut -d" " -f1 /proc/uptime); npm ci --offline --ignore-scripts --no-audit --no-fund --cache /npm >/dev/null; '
                        'e=$(cut -d" " -f1 /proc/uptime); echo "$e $s" | awk \'{print $1-$2}\'')
    rec(engine, "mount", "npm ci --offline (219 packages)", float(out.split()[-1]), "s", "lower")

    fio_dir = ["-v", f"{base}:/w"]
    w = fio(engine, *fio_dir, directory="/w", rw="write", bs="1m", size="1g", end_fsync=1)
    rec(engine, "mount", "seq write 1 GiB", w["bw_bytes"] / 1e6, "MB/s", "higher")
    in_container_times(engine, "drop", "-v", f"{base}:/w")
    r = fio(engine, *fio_dir, directory="/w", rw="read", bs="1m", size="1g")
    rec(engine, "mount", "seq read 1 GiB (host cache warm)", r["bw_bytes"] / 1e6, "MB/s", "higher")
    r = fio(engine, *fio_dir, directory="/w", rw="randread", bs="4k", size="1g", runtime=20, time_based=1)
    rec(engine, "mount", "4k randread", r["iops"], "IOPS", "higher")
    w = fio(engine, *fio_dir, directory="/w", rw="randwrite", bs="4k", size="256m", fsync=1, runtime=20, time_based=1)
    rec(engine, "mount", "4k randwrite + fsync", w["iops"], "IOPS", "higher")

    # A file created on the Mac: how long until the container sees it, and whether inotify fires.
    notify = base / "notify"
    notify.mkdir()
    p = subprocess.Popen(["docker", "run", "--rm", "-v", f"{notify}:/n", TOOLS, "sh", "-c",
                          "echo ready; (inotifywait -q -t 10 -e create /n >/dev/null && echo inotify) & "
                          "i=0; while [ ! -e /n/f ] && [ $i -lt 10000 ]; do usleep 1000; i=$((i+1)); done; "
                          "[ -e /n/f ] && echo seen; wait"],
                         env=engine.env(), stdout=subprocess.PIPE, text=True)
    assert p.stdout.readline().strip() == "ready"
    time.sleep(0.5)  # lets inotifywait set its watch
    t0 = time.monotonic()
    (notify / "f").write_text("x")
    seen = None
    lines = []
    for line in p.stdout:
        lines.append(line.strip())
        if line.strip() == "seen":
            seen = time.monotonic() - t0
    p.wait()
    rec(engine, "mount", "host file visible in container", seen, "s", "lower")
    rec(engine, "mount", "inotify fires for host change", 1.0 if "inotify" in lines else 0.0, "yes=1", "higher")
    safe_rmtree(base)


def suite_network(engine, rec, args):
    try:
        engine.docker("run", "-d", "--name", "dockma-bench-iperf", TOOLS, "iperf3", "-s")
        ip = engine.docker("inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", "dockma-bench-iperf").strip()
        time.sleep(1)
        out = json.loads(engine.docker("run", "--rm", TOOLS, "iperf3", "-c", ip, "-t", "10", "-J"))
        rec(engine, "network", "container↔container (bridge)", out["end"]["sum_received"]["bits_per_second"] / 1e9, "Gbit/s", "higher")

        engine.docker("run", "-d", "--name", "dockma-bench-http", "--tmpfs", "/w:size=1100m", "-p", f"{PORT}:8080", TOOLS,
                      "sh", "-c", "head -c 1073741824 /dev/zero >/w/blob && exec httpd -f -p 8080 -h /w")
        url = f"http://127.0.0.1:{PORT}/blob"
        wait_for(lambda: subprocess.run(["curl", "-sfI", "-o", "/dev/null", url]).returncode == 0, 60, "published port")
        for _ in range(3):
            speed = float(run(["curl", "-sf", "-o", "/dev/null", "-w", "%{speed_download}", url]))
            rec(engine, "network", "published port → macOS (HTTP 1 GiB)", speed * 8 / 1e9, "Gbit/s", "higher")

        if shutil.which("iperf3"):
            server = subprocess.Popen(["iperf3", "-s", "-1", "-p", "18082"], stdout=subprocess.DEVNULL)
            time.sleep(0.5)
            out = json.loads(engine.docker("run", "--rm", "--add-host", f"host.docker.internal:{engine.host_gateway}", TOOLS,
                                           "iperf3", "-c", "host.docker.internal", "-p", "18082", "-t", "10", "-J"))
            server.wait(timeout=30)
            rec(engine, "network", "container → macOS (iperf3)", out["end"]["sum_received"]["bits_per_second"] / 1e9, "Gbit/s", "higher")

            engine.docker("run", "-d", "--name", "dockma-bench-udp", "-p", "18083:5201", "-p", "18083:5201/udp", TOOLS, "iperf3", "-s")
            time.sleep(1)
            out = json.loads(run(["iperf3", "-c", "127.0.0.1", "-p", "18083", "-u", "-b", "0", "-l", "1400", "-t", "10", "-J"]))
            s = out["end"]["sum"]
            rec(engine, "network", "UDP published port, macOS → container", s["bits_per_second"] * (1 - s["lost_percent"] / 100) / 1e9, "Gbit/s", "higher")
        else:
            log("  iperf3 not on the Mac: skipping container → macOS and UDP")
    finally:
        engine.docker("rm", "-f", "dockma-bench-iperf", "dockma-bench-http", "dockma-bench-udp", check=False)


def timed(fn):
    t0 = time.monotonic()
    fn()
    return time.monotonic() - t0


def suite_workload(engine, rec, args):
    for _ in range(5):
        rec(engine, "workload", "docker run --rm true", timed(lambda: engine.docker("run", "--rm", TOOLS, "true")), "s", "lower")

    ctx = WORK / "build" / engine.name
    safe_rmtree(ctx)
    ctx.mkdir(parents=True)
    with tarfile.open(CACHE / f"{GIT_DIR}.tar") as t:
        t.extractall(ctx, filter="data")
    rec(engine, "workload", "docker build: compile git (--no-cache)", timed(lambda: engine.docker(
        "build", "--no-cache", "-q", "-t", "dockma-bench-git", "-f", str(FIXTURES / "build.Dockerfile"), str(ctx / GIT_DIR))), "s", "lower")
    safe_rmtree(ctx)

    compose = ["compose", "-p", "dockma-bench", "-f", str(FIXTURES / "compose.yaml")]
    try:
        rec(engine, "workload", "compose up --wait (postgres+redis)", timed(lambda: engine.docker(*compose, "up", "-d", "--wait")), "s", "lower")
        pg = [*compose, "exec", "-T", "db", "pgbench", "-U", "postgres"]
        rec(engine, "workload", "pgbench -i -s 20", timed(lambda: engine.docker(*pg, "-i", "-q", "-s", "20", "postgres")), "s", "lower")
        out = engine.docker(*pg, "-c", "4", "-j", "4", "-T", "20", "postgres")
        rec(engine, "workload", "pgbench TPS (4 clients, 20 s)", float(re.search(r"tps = ([\d.]+)", out).group(1)), "TPS", "higher")
    finally:
        engine.docker(*compose, "down", "-v", check=False)

    time.sleep(args.idle_settle)
    rec(engine, "workload", "host memory footprint after workload", footprint(engine)[0], "MiB", "lower")


SUITE_FNS = {"boot": suite_boot, "idle": suite_idle, "disk": suite_disk, "mount": suite_mount,
             "network": suite_network, "workload": suite_workload}


def prepare(engine):
    """Builds and saves the images, downloads the git source and seeds the npm cache (network needed)."""
    CACHE.mkdir(parents=True, exist_ok=True)
    engine.docker("build", "-q", "-t", TOOLS, "-f", str(FIXTURES / "tools.Dockerfile"), str(FIXTURES))
    for image in IMAGES[1:]:
        engine.docker("pull", "-q", image)
    engine.docker("save", "-o", str(CACHE / "images.tar"), *IMAGES)
    ids = {i: engine.docker("image", "inspect", "-f", "{{.Id}} {{index .RepoDigests 0}}", i, check=False).strip() for i in IMAGES}
    (CACHE / "images.json").write_text(json.dumps(ids, indent=2))

    xz = CACHE / f"{GIT_DIR}.tar.xz"
    run(["curl", "-fsSLo", str(xz), GIT_URL])
    if run(["shasum", "-a", "256", str(xz)]).split()[0] != GIT_SHA256:
        raise RuntimeError(f"{xz}: sha256 mismatch")
    run(["xz", "-dkf", str(xz)])

    seed = WORK / "npm-seed"
    safe_rmtree(seed)
    seed.mkdir(parents=True)
    for f in ("package.json", "package-lock.json"):
        shutil.copy(FIXTURES / "npm" / f, seed)
    safe_rmtree(CACHE / "npm")
    engine.docker("run", "--rm", "-v", f"{seed}:/p", "-v", f"{CACHE}:/cache", "-w", "/p", "node:22-alpine",
                  "npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund", "--cache", "/cache/npm")
    safe_rmtree(seed)
    log(f"prepared {CACHE}")


def host_meta():
    def sh(*argv):
        return run(argv, check=False).strip()
    return dict(macos=sh("sw_vers", "-productVersion"), build=sh("sw_vers", "-buildVersion"),
                model=sh("sysctl", "-n", "hw.model"), cpus=os.cpu_count(), memsize=sh("sysctl", "-n", "hw.memsize"),
                power=sh("pmset", "-g", "batt").splitlines()[0:1], lowpower=sh("pmset", "-g"), therm=sh("pmset", "-g", "therm"),
                docker_cli=sh("docker", "--version"), compose=sh("docker", "compose", "version"),
                python=platform.python_version())


def daily_engines(bench):
    """Engines not under test that are running now, as (stop, start) pairs."""
    found = []
    daily = Dockma(HOME / ".dockma", binary="dockma")  # launchd keeps the binary that started it
    if daily.is_up():
        found.append(("dockma ~/.dockma", daily.stop, daily.start))
    if shutil.which("limactl"):
        for line in run(["limactl", "list", "--format", "{{.Name}} {{.Status}}"], check=False).splitlines():
            name, status = line.split()
            if status == "Running" and not ("lima" in bench and name == Lima.instance):
                found.append((f"lima {name}", lambda n=name: run(["limactl", "stop", n]), lambda n=name: run(["limactl", "start", n])))
    orb = OrbStack()
    if "orbstack" not in bench and shutil.which("orb") and orb.is_up():
        found.append(("orbstack", orb.stop, orb.start))
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engines", default="dockma,lima,orbstack")
    ap.add_argument("--suites", default=",".join(SUITES))
    ap.add_argument("--rounds", type=int, default=6, help="rounds per engine; round 1 is warm-up (default 6)")
    ap.add_argument("--boot-runs", type=int, default=2, help="boots per engine per round (default 2)")
    ap.add_argument("--idle-settle", type=int, default=120, help="seconds before measuring idle footprint")
    ap.add_argument("--idle-sample", type=int, default=300, help="seconds of idle CPU sampling")
    ap.add_argument("--out", type=Path, default=WORK / "results" / time.strftime("%Y%m%d-%H%M%S"))
    ap.add_argument("--prepare", action="store_true", help="build fixtures with the first engine, then exit")
    ap.add_argument("--wipe-orbstack", action="store_true",
                    help="allow pruning OrbStack, which has one shared engine: deletes ALL its images, containers and volumes")
    args = ap.parse_args()

    engines = [ENGINES[e]() for e in args.engines.split(",")]
    suites = args.suites.split(",")
    if unknown := set(suites) - set(SUITES):
        sys.exit(f"unknown suites: {unknown}")
    if args.prepare:
        if not engines[0].is_up():
            engines[0].start()
        engines[0].assert_identity()
        return prepare(engines[0])
    if any(e.name == "orbstack" for e in engines) and not args.wipe_orbstack:
        sys.exit("benchmarking OrbStack prunes its only engine, deleting all its images, containers and volumes; "
                 "pass --wipe-orbstack to accept that")
    if problems := [p for e in engines if (p := e.check())]:
        sys.exit("\n".join(problems))
    if not (CACHE / "images.tar").exists():
        sys.exit(f"no fixtures in {CACHE}: run with --prepare first")

    args.out.mkdir(parents=True, exist_ok=True)
    rec = Recorder(args.out)
    meta = dict(host=host_meta(), args={k: str(v) for k, v in vars(args).items()},
                images=json.loads((CACHE / "images.json").read_text()), engines={})
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    daily = daily_engines(args.engines.split(","))
    for name, stop, _ in daily:
        log(f"stopping daily engine {name}")
        stop()
    try:
        for r in range(args.rounds):
            rec.round = r
            order = engines[r % len(engines):] + engines[:r % len(engines)]
            for engine in order:
                log(f"round {r + 1}/{args.rounds}: {engine.name}")
                for other in engines:
                    if other is not engine:
                        other.stop()
                if "boot" in suites:
                    suite_boot(engine, rec, args)
                elif not engine.is_up():
                    engine.start()
                engine.assert_identity()
                if "idle" in suites:
                    suite_idle(engine, rec, args)
                engine.docker("system", "prune", "-af", "--volumes")
                rec(engine, "workload", "docker load (4 images)", timed(lambda: engine.docker("load", "-q", "-i", str(CACHE / "images.tar"))), "s", "lower")
                if engine.name not in meta["engines"]:
                    meta["engines"][engine.name] = dict(info=json.loads(engine.docker("info", "--format", "{{json .}}")),
                                                        config=engine.config())
                    (args.out / "meta.json").write_text(json.dumps(meta, indent=2))
                for suite in ("disk", "mount", "network", "workload"):
                    if suite in suites:
                        SUITE_FNS[suite](engine, rec, args)
            for engine in engines:
                engine.stop()
    finally:
        for engine in engines:
            try:
                engine.stop()
            except Exception as e:
                log(f"could not stop {engine.name}: {e}")
        for name, _, start in daily:
            log(f"restarting daily engine {name}")
            start()
    log(f"results in {args.out}; summarize with scripts/bench-report.py {args.out}")


if __name__ == "__main__":
    main()

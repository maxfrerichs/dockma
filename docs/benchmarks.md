# Benchmarks: dockma, Lima and OrbStack

`scripts/bench-compare.py` runs the same workloads against each engine, one engine at a time, with equal resources. Raw results go to `~/dockma-bench-work.noindex/results/<timestamp>/` as `raw.jsonl` (one line per measurement) and `meta.json` (host, versions, the full `docker info` and resource config of each engine). `scripts/bench-report.py <dir>` turns them into tables. Publish the raw files along with the tables.

## Setup

All engines get 4 CPUs and 4 GiB of memory.

```sh
# dockma: a separate state directory, so ~/.dockma stays as it is
DOCKMA_HOME=~/.dockma-bench dockma install
DOCKMA_HOME=~/.dockma-bench dockma config --cpus 4 --memory 4096 --autostart false
# a daemon label: both dockma VMs report "dockma VM", and the script must tell them apart before pruning
echo '{ "labels": ["dockma.bench=1"] }' > ~/.dockma-bench/daemon.json

# Lima: a dedicated, rootful instance (the `docker` template is rootless, with rootlesskit networking)
limactl create --name=bench --cpus=4 --memory=4 --vm-type=vz --mount-type=virtiofs --mount-writable template://docker-rootful

# OrbStack: install it yourself; it adds CLI links and may switch the default docker context.
# OrbStack has one engine, so every round prunes it: all your OrbStack images, containers and
# volumes are deleted. The script refuses OrbStack unless you pass --wipe-orbstack.
orb config set cpu 4
orb config set memory_mib 4096

# Once, with network: builds the tools image, saves all images, fetches the git source, seeds the npm cache
scripts/bench-compare.py --prepare
```

A full run of every suite takes about 12 minutes per engine per round, most of it the idle waits. Idle barely varies, so measure it in a separate pass:

```sh
scripts/bench-compare.py --suites boot,disk,mount,network,workload --rounds 6
scripts/bench-compare.py --suites idle --rounds 2
```

`DOCKMA=<binary>` benchmarks another dockma build, such as a branch's `.build/debug/dockma`. The daily `~/.dockma` is always restarted with the installed `dockma`, because launchd keeps the binary that started it.

Before a run: plug in to power, turn off Low Power Mode, and quit other heavy apps. `meta.json` records the power and thermal state.

## Protocol

- **Only one engine runs at a time.** Engines that are running at start are stopped and restarted at exit. Those are `~/.dockma`, other Lima instances, and OrbStack when it isn't being benchmarked.
- **Rounds are interleaved.** The engine order rotates every round, so drift (heat, background work) is spread across engines. Round 1 is a warm-up and the report leaves it out. The default is 6 rounds, with 2 boots per engine per round.
- **Each engine starts each round clean.** The script checks which engine answers (`docker info`) and aborts on a mismatch. Then it runs `docker system prune -af --volumes` and runs `docker load` on the saved images. No timed step uses the internet.
- **The guest page cache is dropped** before cold reads. The host cache isn't, so results on the bind mount are host-warm.
- The work directory is `~/dockma-bench-work.noindex`. dockma shares only the home directory, and Spotlight skips `.noindex`.

## Suites

| suite | what | why |
|---|---|---|
| boot | stop → `_ping` answers; stop → the start command returns | cold start |
| idle | phys_footprint of the engine's host processes, and their CPU, after a 2-minute settle | cost of leaving it running |
| disk | fio on the container filesystem: 1 GiB sequential write, 4k random writes with fsync | image layers and databases |
| mount | on a bind mount from home: extract the git source, `git add/commit/status`, `find`, `npm ci --offline` of 219 packages, fio, delay before a file created on the Mac shows up, whether inotify fires | dev loops on shared source |
| network | iperf3 over the bridge, 1 GiB over HTTP from a published port, and with `iperf3` on the Mac: container → Mac and UDP on a published port | |
| workload | `docker run --rm true`, `docker load`, compiling git with `docker build --no-cache`, compose up of postgres and redis until healthy, pgbench init and TPS, footprint after the workload | end-to-end |

Images and the source are pinned: the image digests are in `meta.json`, and the git tarball's sha256 is in the script.

## Reading the results

Each cell shows median (IQR, n). The best median is in bold. `≈` marks an engine whose IQR overlaps the best one's: with this many samples, that difference is not clear. Don't publish a ranking built on `≈` cells.

## Known limits

- **Footprint is not fully comparable.** Memory is attributed to the VZ XPC process. OrbStack sizes guest memory dynamically, so a cap of 4 GiB is not 4 GiB held. Report the method next to the number.
- **Disk flush semantics.** dockma and Lima 2.2.1 both attach their disks with `synchronizationMode: .fsync`, which on macOS doesn't flush the drive's cache (no `F_FULLFSYNC`). Their caching modes differ: dockma uses `automatic`, Lima `cached`. OrbStack's settings aren't public. Results that depend on fsync (pgbench, the fsync IOPS rows) compare the same promise for dockma and Lima, but not necessarily for OrbStack.
- **Engines differ in more than the VM.** Docker and BuildKit versions, the storage driver or containerd snapshotter, the cgroup driver and the kernel all differ. All of them are in `meta.json`. A difference in a result may come from any of them.
- **inotify for host changes** is off by default in Lima (`--mount-inotify`). The defaults are measured as shipped.
- Results are for one Mac model. Check `meta.json` before comparing across machines.
- The script's author maintains dockma. Publish the harness, raw data and configs so others can rerun it, and publish all suites, including the ones dockma loses.
- OrbStack's licence terms may restrict publishing benchmarks. Check them before publishing.

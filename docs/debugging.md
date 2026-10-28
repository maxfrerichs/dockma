# Debugging

How to step through dockma: the daemon and CLI with lldb, the guest agent with Delve, and the kernel hook with dynamic debug and tracing. Everything runs against a **debug VM** in `~/.dockma-debug`, beside your own VM in `~/.dockma`, which keeps running. The tours at the end follow the flows of [architecture.md](architecture.md) breakpoint by breakpoint.

## Setup

One time, and again after changes under `vm/`:

```sh
make debug-vm   # signed debug build, the debug guest in vm/out-debug, installed into ~/.dockma-debug
```

The debug guest differs from a release guest in three ways:
- **Delve** (`/usr/bin/dlv`) runs the agent: init respawns [`dockma-agent-debug`](../vm/rootfs-debug/usr/libexec/dockma-agent-debug) instead of the agent, and it listens on port 2345 for a debugger.
- **The agent** is built without optimizations and keeps its symbols.
- **The kernel** adds [`debug.config`](../vm/kernel/debug.config): dynamic debug, ftrace, kprobe events and lockdep.

In VS Code, install the recommended extensions (Swift, Go). The debug configurations and tasks all use `DOCKMA_HOME=~/.dockma-debug`. In a terminal, export it yourself, for every `dockma` command including `dockma shell`; without it, commands reach your own VM.

| Launch configuration | Use it to |
|---|---|
| **Daemon (debug VM)** | Run `dockma daemon` in the foreground under lldb; it boots the VM by itself. Its pre-launch task builds, signs, and stops the debug VM's launchd job, which would hold `daemon.lock`. Don't run `dockma start` against it: `start` sees a daemon outside launchd and returns without waiting. |
| **CLI (debug VM)** | Run one subcommand (`start`, `status`, `stop`) under lldb. |
| **Attach to daemon (launchd)** | Wait for the next `dockma daemon` process and attach. Start it, then run the task **debug VM: start**: this debugs the daemon as launchd runs it. |
| **Agent (Delve in the debug VM)** | Attach to the agent. Get the address from the task **debug VM: guest IP**. |

To debug the agent's startup (`hello`, the first `ports` and `watch`), run the task **debug VM: agent waits for debugger**. The agent restarts and stops before `main` until you attach and continue. **debug VM: agent runs at once** undoes it. Both kill `dlv`, and init starts it again; the wrapper reads `agent-debug-wait` in the state directory.

## Hazards

- **A breakpoint in the daemon stops its main actor.** The VM keeps running, but `control.sock`, the agent's messages and new forwards wait. Deadlines run on a continuous clock: a stop requested before the pause hard-stops the VM right after you continue ([`Daemon.scheduleForceStop`](../Sources/DockmaCore/Daemon/Daemon.swift)).
- **A paused agent stops everything that runs through it:** the Docker socket, port tunnels, DNS for containers, and `dockma shell`. Read guest state before you pause it, or from a shell opened before.
- **Stopping the debugger kills the daemon, and with it the VM,** without a clean shutdown. The data disk is checked at the next boot; nothing is lost that dockerd had synced.
- **Delve listens on all addresses in the VM.** Whatever reaches port 2345 is root in the VM, containers included. Run only containers you trust in the debug VM. Release guests never contain Delve.
- **The Mac reaches the VM's address directly** over Virtualization.framework's NAT, which is how VS Code connects to Delve. dockma's own port forwarding can't carry it, because those tunnels run through the agent you have paused.

## Tours

Each tour starts from a running debug VM unless it says otherwise. Set the breakpoints, run the trigger, and go through the stops in order.

### Start

The CLI and the daemon are two processes, so this tour has two parts. Start each from a stopped debug VM (task **debug VM: stop**).

**The CLI.** Run **CLI (debug VM)** with `start`; launchd starts the daemon as usual. To also catch the daemon's later stops (6–10 below) in this run, launch **Attach to daemon (launchd)** while the CLI sits at stop 1, then continue: lldb attaches once the daemon appears, too late for its boot but in time for the agent and the `wait`.

| Stop | Where | Look at |
|---|---|---|
| 1 | [`Start.run`](../Sources/DockmaCLI/Dockma.swift) | `paths`: the state directory comes from `DOCKMA_HOME`. |
| 2 | [`Start.loadJob`](../Sources/DockmaCLI/Dockma.swift) | Which of the job's states it finds; a stopped VM ends in [`LaunchAgent.install`](../Sources/DockmaCore/Daemon/LaunchAgent.swift). |
| 3 | [`Start.connectToDaemon`](../Sources/DockmaCLI/Dockma.swift) | How it waits for `control.sock`: kqueue on the state directory, with a 1 s fallback until the daemon's pid is known. |
| 4 | [`ControlClient.waitUntilReady`](../Sources/DockmaCore/Daemon/ControlProtocol.swift) | One `wait` request; the reply comes only once Docker is ready, or the connection closes. |

**The daemon.** Launch **Daemon (debug VM)**; it boots the VM itself. To also step through the agent's side, first run **debug VM: agent waits for debugger**, then attach **Agent (Delve in the debug VM)** once the VM has booted.

| Stop | Where | Look at |
|---|---|---|
| 1 | [`Daemon.boot`](../Sources/DockmaCore/Daemon/Daemon.swift) | The control socket listens before anything can fail. `built.configuration`: CPUs, memory, devices. |
| 2 | [`KernelCmdline.commandLine`](../Sources/DockmaCore/VM/KernelCmdline.swift) | The guest's command line: `dockma.home=`, `dockma.state=`, `panic=5`. |
| 3 | [`Daemon.vmStarted`](../Sources/DockmaCore/Daemon/Daemon.swift) | The Docker and shell sockets are served before the agent connects. |
| 4 | [`main`](../vm/agent/main.go) (agent) | With the wait file, Delve holds the agent here. Its servers start before it dials the host. |
| 5 | [`handleControl`](../vm/agent/main.go) (agent) | The first messages: `hello`, then `docker`, `ports`, `watch` from the first snapshot. |
| 6 | [`AgentClient.accept`](../Sources/DockmaCore/Agent/AgentClient.swift) | The agent dialed in; a reader thread per connection. |
| 7 | [`AgentClient.handle`](../Sources/DockmaCore/Agent/AgentClient.swift) | `message.type` for each line; `sender == fd` drops a replaced connection's late lines. |
| 8 | [`portWatcher.setDockerReady`](../vm/agent/main.go) (agent) | Readiness flips once the `/events` stream opens. |
| 9 | [`Daemon.answerReadyWaiters`](../Sources/DockmaCore/Daemon/Daemon.swift) | Answers each pending `wait`. Under the foreground daemon nobody waits, so `readyWaiters` is empty; in the CLI part it holds the CLI's request. |

### A published port

Trigger: `DOCKER_HOST=unix://$HOME/.dockma-debug/docker.sock docker run -d -p 8080:80 nginx`, then `curl localhost:8080`.

| Stop | Where | Look at |
|---|---|---|
| 1 | [`portWatcher.relist`](../vm/agent/main.go) (agent) | `containers`: Docker's list, with ports and mounts. |
| 2 | [`PublishedPorts`](../vm/agent/ports.go) (agent) | Which ports become forwards, and their guest `target`. |
| 3 | [`portWatcher.update`](../vm/agent/main.go) (agent) | Only a change reaches subscribers; `handleControl` then sends `ports`. |
| 4 | [`PortForwarder.update`](../Sources/DockmaCore/Forwarding/PortForwarder.swift) | `plan.toOpen` and `plan.toClose` from [`PortForwarder.plan`](../Sources/DockmaCore/Forwarding/PortForwarder.swift). |
| 5 | [`PortForwarder.tunnel`](../Sources/DockmaCore/Forwarding/PortForwarder.swift) | On `curl`: a fresh vsock connection and the `tcp <target>` line. |
| 6 | [`handleTunnel`](../vm/agent/main.go) (agent) | `network` and `target` from [`parseTunnelHeader`](../vm/agent/main.go), then the dial to docker-proxy. |

For UDP, use `-p 5353:5353/udp` and stop in [`DatagramRelay`](../Sources/DockmaCore/Forwarding/DatagramRelay.swift) and [`relayUDP`](../vm/agent/udp.go).

### File changes on the Mac

Trigger: run a container that bind-mounts a directory under your home and watches it, for example `docker run --rm -v ~/tmp/watch:/w alpine sh -c 'apk add -q inotify-tools && inotifywait -m /w'`, then edit a file in `~/tmp/watch` on the Mac.

| Stop | Where | Look at |
|---|---|---|
| 1 | [`WatchedPaths`](../vm/agent/ports.go) (agent) | The bind sources under home that the agent asks for. |
| 2 | [`FileWatcher.watch`](../Sources/DockmaCore/Agent/FileWatcher.swift) | `requested` against what [`FileWatcher.allowedPaths`](../Sources/DockmaCore/Agent/FileWatcher.swift) keeps. |
| 3 | [`FileWatcher.event`](../Sources/DockmaCore/Agent/FileWatcher.swift) | On the edit: `flags` and `status`; whether it becomes C, M or D. Runs on the watcher's queue, not the main actor. A plain edit to a file created moments before can still carry `ItemCreated`, because FSEvents keeps a file's earlier flags; it becomes C plus M, and the hook raises no second CREATE (`inode already known` in `dmesg`). |
| 4 | [`fileForwarder.enqueue`](../vm/agent/fileevents.go) (agent) | The batch arrives in the control reader and only queues. |
| 5 | [`fileForwarder.apply`](../vm/agent/fileevents.go) (agent) | The worker: C first, then the echo check, then M. |
| 6 | [`fileForwarder.isEcho`](../vm/agent/fileevents.go) (agent) | Write the file from inside the container instead: the Mac's echo matches the guest's own write. |

The kernel side has no debugger. In a shell in the debug VM (`dockma shell`):

```sh
echo 'file dockma_notify.c +p' >/proc/dynamic_debug/control   # the hook's pr_debug lines
dmesg -w                                                        # one line per write: "dockma-notify: M /path: 0"
```

To see the cache invalidation the hook triggers, add a kprobe event:

```sh
mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null
echo 'p:dn_inval fuse_reverse_inval_entry' >/sys/kernel/tracing/kprobe_events
echo 1 >/sys/kernel/tracing/events/kprobes/dn_inval/enable
cat /sys/kernel/tracing/trace_pipe
```

The code behind these lines is [`dn_write`](../vm/kernel/dockma_notify.c) and [`dn_apply`](../vm/kernel/dockma_notify.c). Lockdep (`PROVE_LOCKING`) reports a bad lock order in `dmesg` on its own.

### Stop

Trigger: with the daemon under **Daemon (debug VM)**, run the task **debug VM: stop**. A foreground daemon has no launchd job, so `stop` sends its request over `control.sock`.

| Stop | Where | Look at |
|---|---|---|
| 1 | [`Daemon.handle`](../Sources/DockmaCore/Daemon/Daemon.swift) | `.stop`: the reply is written before `requestStop` runs. |
| 2 | [`Daemon.requestStop`](../Sources/DockmaCore/Daemon/Daemon.swift) | Forwards and listeners close; `isShutdownSent` picks the deadline. |
| 3 | [`Daemon.forceStopDeadline`](../Sources/DockmaCore/Daemon/Daemon.swift) | 25 s after the request with an agent, 2 s without. |
| 4 | [`handleControl`](../vm/agent/main.go) (agent) | `shutdown` runs `poweroff`; init then runs [`shutdown`](../vm/rootfs/etc/init.d/shutdown). |
| 5 | [`Daemon.vmStopped`](../Sources/DockmaCore/Daemon/Daemon.swift) | `error` and `isStopRequested` decide the exit code ([`Daemon.exitCode`](../Sources/DockmaCore/Daemon/Daemon.swift)). |

To see the hard stop, pause the agent at stop 4 for more than 25 s, then continue the daemon.

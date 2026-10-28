# Shell protocol (vsock port 1027)

`dockma shell` runs a command in the VM, on a pseudo-terminal or on plain
pipes, over a small framed protocol. This document specifies that protocol as
the code implements it. The two implementations are:

- **Client (host, Swift):** `ShellFrame` and `ShellFrameDecoder` in
  `Sources/DockmaCore/Shell/ShellProtocol.swift`, driven by `ShellSession` in
  `Sources/DockmaCore/Shell/ShellSession.swift`.
- **Server (guest, Go):** `Handle` and `readInput` in `vm/agent/internal/shell/shell.go` (package `shell`).

Change both together, and update this document with them.

## Transport

```
dockma shell ──unix──► ~/.dockma/shell.sock ──daemon──► vsock port 1027 ──► dockma-agent ──► command
```

- The daemon serves `shell.sock` with `VsockSocketProxy`: it connects to the
  agent's port 1027 for each accepted connection and copies bytes both ways.
  It does not parse frames.
- The agent accepts connections only from the host (CID 2, `isHostPeer`).
- **One connection carries one session.** The agent closes the connection when
  the session ends.
- The command runs as root, in `/root`, with exactly this environment:
  `PATH=/usr/sbin:/usr/bin:/sbin:/bin`, `HOME=/root`, `USER=root`,
  `SHELL=/bin/sh`, `TERM=<term from start>`.

## Framing

Every message in both directions is one frame:

```
 0        1                 5
+--------+-----------------+-------------------------+
| type   | length          | payload (length bytes)  |
| u8     | u32 big-endian  |                         |
+--------+-----------------+-------------------------+
```

- All integers in headers and payloads are big-endian.
- `length` is the payload size only; the header is always 5 bytes.
- The maximum payload is 1 MiB (`1 << 20`). The client's decoder throws on a
  larger length; the agent treats it as a read error, which ends the session as
  a disconnect does (see [Exit and teardown](#exit-and-teardown)).

## Frame types

Client → agent:

| Type | Name       | Payload | Notes |
|-----:|------------|---------|-------|
| 1    | `start`    | JSON object, see [below](#the-start-frame) | Must be the first frame. |
| 2    | `stdin`    | raw bytes | Input for the command. With flow control, limited by credit. |
| 3    | `stdinEOF` | empty | Pipes: close the command's stdin once queued input is written. TTY: the pty stays open. With flow control, later `stdin` is dropped. |
| 4    | `resize`   | `rows u16, cols u16` (4 bytes) | TTY: sets the pty's window size. Pipes: ignored. |
| 5    | `signal`   | signal number `u8` (1 byte) | Sent to the command's process group. Only 1, 2 and 15 are acted on. |

Agent → client:

| Type | Name      | Payload | Notes |
|-----:|-----------|---------|-------|
| 16   | `stdout`  | raw bytes | All output in TTY mode; standard output with pipes. |
| 17   | `stderr`  | raw bytes | Standard error with pipes; also the "command not found" message. |
| 18   | `exit`    | exit code `i32` (4 bytes) | Last frame of a session that ran. |
| 19   | `error`   | UTF-8 message | The session is over; no `exit` follows. |
| 20   | `started` | empty | The command is running. Sent once, before any output. |
| 21   | `window`  | stdin credit `u32` in bytes (4 bytes) | Only when `start` asked for flow control. |

Types 0, 6–15 and 22–255 are unassigned.

### The `start` frame

The payload is a JSON object. Its keys are frozen: they are the Codable
property names of `ShellStart` and the JSON tags of the Go `shellStart`.

| Key    | Type            | Meaning | If empty or zero |
|--------|-----------------|---------|------------------|
| `argv` | array of string | Command and arguments. `argv[0]` is looked up in `PATH`. | `["/bin/sh", "-l"]`, a login shell |
| `tty`  | bool            | Run on a pty (`true`) or on pipes (`false`). | pipes |
| `rows` | u16             | Initial pty height. | 24 |
| `cols` | u16             | Initial pty width. | 80 |
| `term` | string          | Value of `TERM`. | `xterm-256color` |
| `flow` | bool            | Ask for stdin flow control (see [below](#stdin-flow-control)). | off |

The Swift client always sends `flow: true`. Key order does not matter; agents
ignore unknown keys (Go's `encoding/json` default).

## Session sequence

A session that runs:

```
client                                       agent
  │ start {argv, tty, rows, cols, term, flow}  │
  │──────────────────────────────────────────►│  spawn the command
  │                       window 262144       │  (only if flow)
  │◄──────────────────────────────────────────│
  │                       started             │
  │◄──────────────────────────────────────────│
  │ stdin / resize / signal / stdinEOF        │
  │──────────────────────────────────────────►│
  │            stdout / stderr / window       │
  │◄──────────────────────────────────────────│
  │                       exit <code>         │  command exited, output drained
  │◄──────────────────────────────────────────│  agent closes the connection
```

`window` and `started` are written before the agent starts reading client
frames, so the client never has to send anything after `start` before it knows
whether it has credit.

Sessions that do not run:

| Situation | Agent sends |
|-----------|-------------|
| The first frame is not `start` | `error "protocol error: first frame must be start"` |
| The `start` payload is not valid JSON for `shellStart` | `error "protocol error: <decoder error>"` |
| `argv[0]` does not exist | `stderr "<argv[0]>: command not found\n"`, then `exit 127` (no `started`) |
| Any other spawn failure (pipes, pty, exec) | `error "cannot run <argv[0]>: <error>"` or the pipe error |
| The connection fails before a full first frame, or the first frame is over 1 MiB | nothing; the agent closes the connection |

## TTY and pipe modes

**TTY** (`tty: true`):

- The command runs on a pty of the requested size, in its own session with the
  pty as controlling terminal (creack/pty's `Setsid` and `Setctty`).
- All output, including the command's stderr, arrives as `stdout`.
- `resize` frames set the window size.
- `stdinEOF` never closes the pty. Without flow control the agent ignores it.
  With flow control, input queued before it is still written, but `stdin`
  sent after it is dropped and its credit is not returned. The Swift client
  sends `stdinEOF` only when its own stdin has ended, so this doesn't arise.
- The Swift client puts the local terminal in raw mode, so ^C, ^Z and ^\
  travel as `stdin` bytes and the pty's line discipline turns them into
  signals. It does not send `signal` frames in this mode; SIGTERM or SIGHUP to
  the client restores the terminal and exits it with 128 + the signal number,
  which the agent sees as a disconnect.

**Pipes** (`tty: false`):

- The command runs in a new session (`setsid`) with separate pipes for stdin,
  stdout and stderr, forwarded as `stdout` and `stderr` frames.
- `stdinEOF` closes the command's stdin after any queued input is written.
- `resize` is ignored.
- The Swift client forwards SIGINT, SIGTERM and SIGHUP it receives as `signal`
  frames instead of acting on them.

## Stdin flow control

Without flow control, the agent writes each `stdin` payload to the command
synchronously, on the same loop that reads client frames. A command that does
not read its stdin then blocks that loop, and `signal` and `resize` frames
behind the unread stdin are never applied: a ^C can't reach a stuck command.

With `flow: true`:

1. The agent grants **262144 bytes** (256 KiB) of credit up front, in a
   `window` frame sent before `started`.
2. The client sends at most its current credit in `stdin` payloads, and
   decrements its credit by each payload's length. At zero credit it waits.
3. The agent queues `stdin` payloads and writes them to the command on a
   separate goroutine. After writing a payload it returns that payload's length
   as a `window` frame. Credit comes back even when the write failed because
   the command closed its stdin; that input is dropped, as it would be without
   flow control.
4. The frame-reading loop never blocks on the command, so `signal`, `resize`
   and `stdinEOF` are applied as soon as they arrive. `stdinEOF` still takes
   effect only after the queued input ahead of it; `stdin` sent after
   `stdinEOF` is dropped without returning credit, in both modes.

A client that sends beyond its credit is still bounded: the agent's queue
blocks the reading loop once it would exceed 256 KiB, which brings back the
non-flow behaviour for that client only.

**Detecting an older agent.** Agents that predate flow control ignore the
`flow` key and never send `window`. The client therefore decides from the
first of the two frames it sees:

- `window` before `started`: credit-based flow control.
- `started` alone: unlimited; send stdin freely.

The Swift client holds back stdin until one of the two arrives.

## Signals

- The payload is one byte, the signal number. The agent sends it to the
  command's process group (`kill(-pid, sig)`), so children of a shell get it
  too.
- The agent acts only on SIGHUP (1), SIGINT (2) and SIGTERM (15). Every other
  number, and a payload that is not exactly one byte, is ignored.
- Numbers are Linux's. They coincide with macOS's for these three, which is
  why the Swift client can send its own constants (`SIGINT` etc.) unchanged.

## Exit and teardown

**Exit code.** The `exit` payload is a signed 32-bit integer:

- the command's exit status;
- 128 + n when the command was killed by signal n (so SIGTERM gives 143);
- 255 when the agent has no process state for the command;
- 127 when the command does not exist (see above).

**Draining.** After the command exits, the agent waits up to **200 ms** for its
output copiers to finish, because background processes can keep the pty or
pipes open indefinitely. Then it closes its ends of the output:

- Pipes: closing unblocks the copiers, so all output read so far is sent
  before `exit`.
- TTY: the agent does not wait for the pty copier (closing can't interrupt a
  blocked read on the pty). With `sleep 600 &` then `exit`, the session ends
  after the 200 ms drain timeout, not after 600 s.

The agent sends nothing after `exit`; output still arriving is dropped. It then
closes the connection.

**Client disconnect.** If the connection closes or fails (including an
oversized frame) while the command is still running, the agent sends SIGHUP to
the process group, waits up to **2 s** for the command to exit, then sends
SIGKILL.

**VM stop or restart.** `dockma stop` or `dockma restart` closes an open
session's connection without an `exit` frame. The client prints "connection to
the VM closed (VM stopped or restarted?)" and exits with 255. (Checked by hand
with `dockma restart`.)

**Guest reboot.** When the guest reboots in place (`reboot -f`, or a kernel
panic with `panic=5`), the agent and the command are gone, but the client is
not told: it receives no `exit` and its connection stays open. The session
ends only when the client next writes a frame (in TTY mode, the next
keypress); then the connection closes and the client prints "connection to
the VM closed (VM stopped or restarted?)" and exits with 255. A client that
has nothing left to send, such as a pipe-mode session after `stdinEOF`, waits
forever. This is a known bug, not a protocol rule. (Checked by hand with
`dockma shell -- reboot -f` and a second open session.)

**Client results.** `dockma shell` exits with the code from `exit`. It prints
a message and exits with 255 when it receives `error`, when a frame fails to
decode, or when the connection closes without `exit`. In the last case the
message depends on whether `started` was seen: without it, the agent most
likely predates `dockma shell` (the guest image is older than the CLI).

## Robustness and evolution

- **Agent leniency.** The agent logs and ignores unknown client frame types,
  and ignores `resize` and `signal` frames with a wrong payload size.
- **Client strictness.** The Swift decoder throws on unknown agent frame types
  and on `resize`, `signal`, `exit` and `window` frames with a wrong payload
  size, which ends the session with 255.
- **Adding features.** Because of that asymmetry, a new client → agent frame
  is safe to add (old agents ignore it), but a new agent → client frame must be
  opt-in: the client asks for it with a new `start` key, which old agents
  ignore. `flow` and `window` were added this way. Payload changes to existing
  frames are incompatible.
- **Incompatible changes** bump `GuestImage.protocolVersion` and
  `vm/agent/protocol` together, so `dockma start` refuses a mismatched guest.

## Test vectors

These bytes are asserted by both test suites
(`Tests/DockmaCoreTests/ShellProtocolTests.swift` and
`vm/agent/internal/shell/shell_test.go`):

| Frame | Hex |
|-------|-----|
| `resize` 24 rows × 80 cols | `04 00000004 0018 0050` |
| `window` 262144 | `15 00000004 00040000` |

More examples, derived from the rules above:

| Frame | Hex |
|-------|-----|
| `stdinEOF` | `03 00000000` |
| `signal` SIGINT | `05 00000001 02` |
| `started` | `14 00000000` |
| `exit` 130 | `12 00000004 00000082` |
| `start` with the 82-byte payload `{"argv":["uname","-a"],"tty":false,"rows":24,"cols":80,"term":"xterm","flow":true}` | `01 00000052` followed by the payload |

## Source map

| Concern | Swift | Go |
|---------|-------|----|
| Frame types, encoding, decoding | `ShellFrame`, `ShellFrameDecoder` (`ShellProtocol.swift`) | constants, `readFrame`, `encodeFrame` (`shell.go`) |
| `start` payload | `ShellStart` | `shellStart` |
| Session driver | `ShellSession.run`, `receive`, `pumpStdin` | `shell.Handle`, `readInput` |
| Flow control | `ShellSession.takeCredit` | `stdinQueue`, `writeStdin`, `stdinWindow` |
| Teardown timings | — | `outputDrainTimeout`, `hangupGrace` |
| Daemon proxy | `VsockSocketProxy` | — |
| Tests | `Tests/DockmaCoreTests/ShellProtocolTests.swift` | `vm/agent/internal/shell/shell_test.go` |

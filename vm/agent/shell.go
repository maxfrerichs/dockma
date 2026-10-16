package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

// Shell session frames: [type u8][length u32 big-endian][payload]. Mirrors
// ShellFrame in Sources/dockma/ShellProtocol.swift; keep the two in sync.
const (
	frameStart    byte = 1  // client: JSON shellStart, always first
	frameStdin    byte = 2  // client: input bytes
	frameStdinEOF byte = 3  // client: close the child's stdin (non-TTY)
	frameResize   byte = 4  // client: rows u16, cols u16
	frameSignal   byte = 5  // client: signal number u8 for the process group
	frameStdout   byte = 16 // agent: output bytes (all output in TTY mode)
	frameStderr   byte = 17 // agent: error output bytes (non-TTY mode)
	frameExit     byte = 18 // agent: exit code i32, 128+n when killed by signal n
	frameError    byte = 19 // agent: UTF-8 message; the session is over
	frameStarted  byte = 20 // agent: the command is running (lets the client tell a dropped session from an old agent)
	frameWindow   byte = 21 // agent: stdin credit u32 in bytes (only when the client asked for flow control)

	maxFrameSize = 1 << 20
	// Stdin credit granted up front. A client with flow control never has
	// more stdin than this in flight, so the agent can always keep reading
	// the connection: signals and resizes never wait behind unread stdin.
	stdinWindow = 256 * 1024
	// How long output may keep flowing after the command exited; background
	// processes can hold the pty or pipes open indefinitely.
	outputDrainTimeout = 200 * time.Millisecond
	// Grace period between SIGHUP and SIGKILL when the client disconnects.
	hangupGrace = 2 * time.Second
)

type shellStart struct {
	Argv []string `json:"argv"`
	TTY  bool     `json:"tty"`
	Rows uint16   `json:"rows"`
	Cols uint16   `json:"cols"`
	Term string   `json:"term"`
	Flow bool     `json:"flow"`
}

func readFrame(r io.Reader) (byte, []byte, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(header[1:])
	if n > maxFrameSize {
		return 0, nil, fmt.Errorf("frame of %d bytes exceeds the %d byte limit", n, maxFrameSize)
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, nil, err
	}
	return header[0], payload, nil
}

func encodeFrame(t byte, payload []byte) []byte {
	buf := make([]byte, 5+len(payload))
	buf[0] = t
	binary.BigEndian.PutUint32(buf[1:5], uint32(len(payload)))
	copy(buf[5:], payload)
	return buf
}

var errSessionOver = errors.New("session is over")

// frameWriter serializes frames from the output copiers and the session.
// Nothing is written after the exit frame.
type frameWriter struct {
	mu   sync.Mutex
	w    io.Writer
	done bool
}

func (fw *frameWriter) write(t byte, payload []byte) error {
	fw.mu.Lock()
	defer fw.mu.Unlock()
	if fw.done {
		return errSessionOver
	}
	_, err := fw.w.Write(encodeFrame(t, payload))
	return err
}

func (fw *frameWriter) exit(code int) error {
	var p [4]byte
	binary.BigEndian.PutUint32(p[:], uint32(int32(code)))
	fw.mu.Lock()
	defer fw.mu.Unlock()
	if fw.done {
		return errSessionOver
	}
	fw.done = true
	_, err := fw.w.Write(encodeFrame(frameExit, p[:]))
	return err
}

func uint32Payload(n int) []byte {
	var p [4]byte
	binary.BigEndian.PutUint32(p[:], uint32(n))
	return p[:]
}

// stdinQueue holds stdin until the command reads it, so readInput never
// blocks on a command that doesn't. A client within its credit keeps the
// queue under stdinWindow; push waits beyond that only for a client that
// ignores its credit, which keeps memory bounded either way.
type stdinQueue struct {
	mu     sync.Mutex
	cond   *sync.Cond
	chunks [][]byte
	size   int
	eof    bool // stdinEOF received; queued data still goes first
	closed bool // the session is over
}

func newStdinQueue() *stdinQueue {
	q := &stdinQueue{}
	q.cond = sync.NewCond(&q.mu)
	return q
}

func (q *stdinQueue) push(p []byte) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for q.size > 0 && q.size+len(p) > stdinWindow && !q.closed {
		q.cond.Wait()
	}
	if q.closed || q.eof {
		return
	}
	q.chunks = append(q.chunks, p)
	q.size += len(p)
	q.cond.Broadcast()
}

func (q *stdinQueue) closeInput() {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.eof = true
	q.cond.Broadcast()
}

func (q *stdinQueue) close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.closed = true
	q.chunks = nil
	q.cond.Broadcast()
}

// next waits for the next chunk. It reports eof once the queue is drained
// after stdinEOF, and ok=false when the session is over.
func (q *stdinQueue) next() (p []byte, eof, ok bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for len(q.chunks) == 0 && !q.eof && !q.closed {
		q.cond.Wait()
	}
	switch {
	case q.closed:
		return nil, false, false
	case len(q.chunks) == 0:
		return nil, true, true
	}
	p = q.chunks[0]
	q.chunks = q.chunks[1:]
	q.size -= len(p)
	q.cond.Broadcast()
	return p, false, true
}

// writeStdin feeds queued stdin to the command and returns the credit.
func writeStdin(q *stdinQueue, stdin io.WriteCloser, tty bool, fw *frameWriter) {
	for {
		p, eof, ok := q.next()
		if !ok {
			return
		}
		if eof {
			if !tty {
				stdin.Close()
			}
			return
		}
		// A command that closed its stdin drops the data, as without flow
		// control; the credit comes back either way.
		stdin.Write(p)
		if fw.write(frameWindow, uint32Payload(len(p))) != nil {
			return
		}
	}
}

// copyFrames forwards r as frames of type t until EOF or error.
func copyFrames(fw *frameWriter, t byte, r io.Reader, done *sync.WaitGroup) {
	defer done.Done()
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 && fw.write(t, buf[:n]) != nil {
			return
		}
		if err != nil {
			return
		}
	}
}

// handleShell runs one session: a command (default: login shell) with a PTY
// or with plain pipes, driven by frames on c.
func handleShell(c net.Conn) {
	defer c.Close()
	fw := &frameWriter{w: c}

	t, payload, err := readFrame(c)
	if err != nil {
		return
	}
	var start shellStart
	if t != frameStart {
		fw.write(frameError, []byte("protocol error: first frame must be start"))
		return
	}
	if err := json.Unmarshal(payload, &start); err != nil {
		fw.write(frameError, []byte("protocol error: "+err.Error()))
		return
	}
	argv := start.Argv
	if len(argv) == 0 {
		argv = []string{"/bin/sh", "-l"}
	}
	term := start.Term
	if term == "" {
		term = "xterm-256color"
	}

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = "/root"
	cmd.Env = []string{
		"PATH=/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME=/root",
		"USER=root",
		"SHELL=/bin/sh",
		"TERM=" + term,
	}

	var (
		outputs sync.WaitGroup
		closers []io.Closer // read ends of the child's output, closed after the drain
		stdin   io.WriteCloser
		ptmx    *os.File
	)
	if start.TTY {
		ptmx, err = pty.StartWithSize(cmd, &pty.Winsize{Rows: orDefault(start.Rows, 24), Cols: orDefault(start.Cols, 80)})
		if err != nil {
			startFailed(fw, argv[0], err)
			return
		}
		stdin = ptmx
		closers = append(closers, ptmx)
		outputs.Add(1)
		go copyFrames(fw, frameStdout, ptmx, &outputs)
	} else {
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		stdinR, stdinW, err1 := os.Pipe()
		stdoutR, stdoutW, err2 := os.Pipe()
		stderrR, stderrW, err3 := os.Pipe()
		if err := errors.Join(err1, err2, err3); err != nil {
			fw.write(frameError, []byte(err.Error()))
			return
		}
		cmd.Stdin, cmd.Stdout, cmd.Stderr = stdinR, stdoutW, stderrW
		err := cmd.Start()
		// The child has its own copies; the parent keeps only its ends.
		stdinR.Close()
		stdoutW.Close()
		stderrW.Close()
		if err != nil {
			stdinW.Close()
			stdoutR.Close()
			stderrR.Close()
			startFailed(fw, argv[0], err)
			return
		}
		stdin = stdinW
		closers = append(closers, stdoutR, stderrR)
		outputs.Add(2)
		go copyFrames(fw, frameStdout, stdoutR, &outputs)
		go copyFrames(fw, frameStderr, stderrR, &outputs)
	}

	var queue *stdinQueue
	if start.Flow {
		queue = newStdinQueue()
		go writeStdin(queue, stdin, start.TTY, fw)
		fw.write(frameWindow, uint32Payload(stdinWindow))
	}
	fw.write(frameStarted, nil)
	exited := make(chan struct{})
	go readInput(c, cmd.Process.Pid, stdin, ptmx, queue, exited)

	err = cmd.Wait()
	close(exited)
	if queue != nil {
		queue.close()
	}

	drained := make(chan struct{})
	go func() { outputs.Wait(); close(drained) }()
	select {
	case <-drained:
	case <-time.After(outputDrainTimeout):
	}
	for _, closer := range closers {
		closer.Close()
	}
	// Closing a pipe unblocks its copier, so wait for the last output. Not so
	// for the pty: creack/pty's ioctls call File.Fd, which puts ptmx in
	// blocking mode, and Close can't interrupt a blocked Read. Waiting would
	// hold the session open for as long as a background job keeps the
	// terminal (`sleep 600 &` then `exit`). The copier ends when the job
	// closes the terminal; the writer drops its output after the exit frame.
	if !start.TTY {
		<-drained
		stdin.Close()
	}
	fw.exit(exitCode(cmd, err))
}

// readInput applies client frames until the connection closes. A client that
// disconnects mid-session hangs up the process group, then kills it. With
// flow control (queue != nil) stdin goes through the queue, so this loop
// never blocks on a command that doesn't read its input.
func readInput(c net.Conn, pid int, stdin io.WriteCloser, ptmx *os.File, queue *stdinQueue, exited <-chan struct{}) {
	for {
		t, payload, err := readFrame(c)
		if err != nil {
			select {
			case <-exited:
				return
			default:
			}
			syscall.Kill(-pid, syscall.SIGHUP)
			select {
			case <-exited:
			case <-time.After(hangupGrace):
				syscall.Kill(-pid, syscall.SIGKILL)
			}
			return
		}
		switch t {
		case frameStdin:
			if queue != nil {
				queue.push(payload)
			} else {
				stdin.Write(payload)
			}
		case frameStdinEOF:
			if queue != nil {
				queue.closeInput()
			} else if ptmx == nil {
				stdin.Close()
			}
		case frameResize:
			if ptmx != nil && len(payload) == 4 {
				pty.Setsize(ptmx, &pty.Winsize{
					Rows: binary.BigEndian.Uint16(payload[0:2]),
					Cols: binary.BigEndian.Uint16(payload[2:4]),
				})
			}
		case frameSignal:
			if len(payload) == 1 {
				switch sig := syscall.Signal(payload[0]); sig {
				case syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP:
					syscall.Kill(-pid, sig)
				}
			}
		default:
			log.Printf("shell: ignoring frame type %d", t)
		}
	}
}

// startFailed reports a command that could not be started. A missing binary
// behaves like a shell would: message on stderr, exit code 127.
func startFailed(fw *frameWriter, name string, err error) {
	if errors.Is(err, exec.ErrNotFound) || errors.Is(err, os.ErrNotExist) {
		fw.write(frameStderr, []byte(name+": command not found\n"))
		fw.exit(127)
		return
	}
	fw.write(frameError, []byte(fmt.Sprintf("cannot run %s: %v", name, err)))
}

func exitCode(cmd *exec.Cmd, err error) int {
	if cmd.ProcessState == nil {
		return 255
	}
	if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return cmd.ProcessState.ExitCode()
}

func orDefault(v, d uint16) uint16 {
	if v == 0 {
		return d
	}
	return v
}

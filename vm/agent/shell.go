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

	maxFrameSize = 1 << 20
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

	fw.write(frameStarted, nil)
	exited := make(chan struct{})
	go readInput(c, cmd.Process.Pid, stdin, ptmx, exited)

	err = cmd.Wait()
	close(exited)

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
// disconnects mid-session hangs up the process group, then kills it.
func readInput(c net.Conn, pid int, stdin io.WriteCloser, ptmx *os.File, exited <-chan struct{}) {
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
			stdin.Write(payload)
		case frameStdinEOF:
			if ptmx == nil {
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

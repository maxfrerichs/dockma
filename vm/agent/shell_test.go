package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The same bytes are asserted in Tests/dockmaTests/ShellProtocolTests.swift.
func TestResizeFrameGolden(t *testing.T) {
	payload := make([]byte, 4)
	binary.BigEndian.PutUint16(payload[0:2], 24)
	binary.BigEndian.PutUint16(payload[2:4], 80)
	if got := hex.EncodeToString(encodeFrame(frameResize, payload)); got != "04000000040018"+"0050" {
		t.Fatalf("resize frame = %s", got)
	}
}

// The same bytes are asserted in Tests/dockmaTests/ShellProtocolTests.swift.
func TestWindowFrameGolden(t *testing.T) {
	if got := hex.EncodeToString(encodeFrame(frameWindow, uint32Payload(stdinWindow))); got != "15000000040004"+"0000" {
		t.Fatalf("window frame = %s", got)
	}
}

func TestFrameRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	buf.Write(encodeFrame(frameStdout, []byte("hello")))
	buf.Write(encodeFrame(frameStdinEOF, nil))
	typ, payload, err := readFrame(&buf)
	if err != nil || typ != frameStdout || string(payload) != "hello" {
		t.Fatalf("got %d %q %v", typ, payload, err)
	}
	typ, payload, err = readFrame(&buf)
	if err != nil || typ != frameStdinEOF || len(payload) != 0 {
		t.Fatalf("got %d %q %v", typ, payload, err)
	}
}

func TestReadFrameRejectsOversized(t *testing.T) {
	header := []byte{frameStdin, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(header[1:], maxFrameSize+1)
	if _, _, err := readFrame(bytes.NewReader(header)); err == nil {
		t.Fatal("expected an error for an oversized frame")
	}
}

type sessionResult struct {
	stdout, stderr      string
	exit                int
	errMsg              string
	window              uint32 // total stdin credit granted
	windowBeforeStarted bool
}

// runSession drives handleShell over an in-memory connection.
func runSession(t *testing.T, start shellStart, input ...[]byte) sessionResult {
	t.Helper()
	client, server := net.Pipe()
	go handleShell(server)
	defer client.Close()
	client.SetDeadline(time.Now().Add(10 * time.Second))

	payload, _ := json.Marshal(start)
	go func() {
		client.Write(encodeFrame(frameStart, payload))
		for _, frame := range input {
			client.Write(frame)
		}
	}()

	var res sessionResult
	started := false
	for {
		typ, p, err := readFrame(client)
		if err != nil {
			t.Fatalf("session ended without exit frame: %v (so far %+v)", err, res)
		}
		// Only a start failure (error, or stderr+exit for a missing command)
		// may skip the started frame.
		if !started && typ == frameStdout {
			t.Fatalf("output arrived before started")
		}
		switch typ {
		case frameStarted:
			started = true
		case frameWindow:
			if !started && res.window == 0 {
				res.windowBeforeStarted = true
			}
			res.window += binary.BigEndian.Uint32(p)
		case frameStdout:
			res.stdout += string(p)
		case frameStderr:
			res.stderr += string(p)
		case frameExit:
			res.exit = int(int32(binary.BigEndian.Uint32(p)))
			return res
		case frameError:
			res.errMsg = string(p)
			return res
		}
	}
}

func TestSessionSeparatesOutputAndReturnsExitCode(t *testing.T) {
	res := runSession(t, shellStart{Argv: []string{"sh", "-c", "echo out; echo err >&2; exit 3"}})
	if res.stdout != "out\n" || res.stderr != "err\n" || res.exit != 3 {
		t.Fatalf("got %+v", res)
	}
}

func TestSessionPipesStdinUntilEOF(t *testing.T) {
	res := runSession(t, shellStart{Argv: []string{"cat"}},
		encodeFrame(frameStdin, []byte("hello ")),
		encodeFrame(frameStdin, []byte("world")),
		encodeFrame(frameStdinEOF, nil))
	if res.stdout != "hello world" || res.exit != 0 {
		t.Fatalf("got %+v", res)
	}
}

func TestSessionReportsSignalExit(t *testing.T) {
	res := runSession(t, shellStart{Argv: []string{"sh", "-c", "kill -TERM $$"}})
	if res.exit != 128+15 {
		t.Fatalf("got %+v", res)
	}
}

func TestSessionCommandNotFound(t *testing.T) {
	res := runSession(t, shellStart{Argv: []string{"no-such-command-dockma"}})
	if res.exit != 127 || !strings.Contains(res.stderr, "command not found") {
		t.Fatalf("got %+v", res)
	}
}

func TestSessionRejectsMissingStart(t *testing.T) {
	client, server := net.Pipe()
	go handleShell(server)
	defer client.Close()
	client.SetDeadline(time.Now().Add(5 * time.Second))
	go client.Write(encodeFrame(frameStdin, []byte("x")))
	typ, _, err := readFrame(client)
	if err != nil || typ != frameError {
		t.Fatalf("got type %d, err %v", typ, err)
	}
}

func TestSessionWithTTY(t *testing.T) {
	if _, err := os.Stat("/dev/ptmx"); err != nil {
		t.Skip("no /dev/ptmx in this environment")
	}
	res := runSession(t, shellStart{Argv: []string{"sh", "-c", "tty; stty size; exit 5"}, TTY: true, Rows: 30, Cols: 100})
	if res.errMsg != "" {
		t.Skipf("pty unavailable: %s", res.errMsg)
	}
	if !strings.Contains(res.stdout, "/dev/pts/") || !strings.Contains(res.stdout, "30 100") || res.exit != 5 {
		t.Fatalf("got %+v", res)
	}
}

// A background job that keeps the terminal open (job control puts it in its
// own process group, so the hangup on exit doesn't reach it) must not hold
// the session open.
func TestSessionWithTTYDoesNotWaitForBackgroundJob(t *testing.T) {
	if _, err := os.Stat("/dev/ptmx"); err != nil {
		t.Skip("no /dev/ptmx in this environment")
	}
	began := time.Now()
	res := runSession(t, shellStart{Argv: []string{"sh", "-c", "set -m; sleep 30 & echo hi; exit 0"}, TTY: true})
	if res.errMsg != "" {
		t.Skipf("pty unavailable: %s", res.errMsg)
	}
	if elapsed := time.Since(began); elapsed > 2*time.Second || res.exit != 0 || !strings.Contains(res.stdout, "hi") {
		t.Fatalf("after %v got %+v", elapsed, res)
	}
}

// With flow control the client may have a full window of stdin in flight
// that the command never reads, far more than a pipe holds (64 KiB). The
// signal behind it must still arrive.
func TestSignalOvertakesUnreadStdin(t *testing.T) {
	chunk := make([]byte, 32*1024)
	var input [][]byte
	for sent := 0; sent < stdinWindow; sent += len(chunk) {
		input = append(input, encodeFrame(frameStdin, chunk))
	}
	input = append(input, encodeFrame(frameSignal, []byte{byte(syscall.SIGINT)}))
	began := time.Now()
	res := runSession(t, shellStart{Argv: []string{"sleep", "5"}, Flow: true}, input...)
	if elapsed := time.Since(began); elapsed > time.Second || res.exit != 130 {
		t.Fatalf("after %v got %+v", elapsed, res)
	}
}

func TestFlowControlReturnsCredit(t *testing.T) {
	res := runSession(t, shellStart{Argv: []string{"cat"}, Flow: true},
		encodeFrame(frameStdin, []byte("hello ")),
		encodeFrame(frameStdin, []byte("world")),
		encodeFrame(frameStdinEOF, nil))
	if res.stdout != "hello world" || res.exit != 0 || !res.windowBeforeStarted || res.window != stdinWindow+11 {
		t.Fatalf("got %+v", res)
	}
}

// Clients that predate flow control get no window frames.
func TestSessionWithoutFlowSendsNoWindow(t *testing.T) {
	res := runSession(t, shellStart{Argv: []string{"cat"}},
		encodeFrame(frameStdin, []byte("x")),
		encodeFrame(frameStdinEOF, nil))
	if res.stdout != "x" || res.window != 0 {
		t.Fatalf("got %+v", res)
	}
}

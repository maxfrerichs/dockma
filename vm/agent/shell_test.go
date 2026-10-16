package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"strings"
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
	stdout, stderr string
	exit           int
	errMsg         string
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

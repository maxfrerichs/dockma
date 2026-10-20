package main

import (
	"bytes"
	"errors"
	"io"
	"net"
	"path/filepath"
	"testing"
	"time"
)

func TestParseTunnelHeader(t *testing.T) {
	cases := []struct {
		line, network, target string
		ok                    bool
	}{
		{"tcp 127.0.0.1:8080\n", "tcp", "127.0.0.1:8080", true},
		{"tcp [::1]:443\n", "tcp", "[::1]:443", true},
		{"udp 127.0.0.1:53\n", "udp", "127.0.0.1:53", true},
		{"udp [::1]:53\n", "udp", "[::1]:53", true},
		{"udp 127.0.0.1\n", "", "", false},
		{"sctp 127.0.0.1:9\n", "", "", false},
		{"tcp 127.0.0.1\n", "", "", false},
		{"tcp\n", "", "", false},
		{"", "", "", false},
	}
	for _, c := range cases {
		network, target, err := parseTunnelHeader(c.line)
		if (err == nil) != c.ok || network != c.network || target != c.target {
			t.Errorf("parseTunnelHeader(%q) = %q, %q, %v; want %q, %q, ok=%v",
				c.line, network, target, err, c.network, c.target, c.ok)
		}
	}
}

// tcpPair returns both ends of a loopback TCP connection.
func tcpPair(t *testing.T) (net.Conn, net.Conn) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	dialed, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	accepted, err := l.Accept()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dialed.Close(); accepted.Close() })
	return dialed, accepted
}

// pipeAsync runs pipe(a, b) and returns a channel closed when it returns.
func pipeAsync(a, b net.Conn, aReader io.Reader) <-chan struct{} {
	done := make(chan struct{})
	go func() { pipe(a, b, aReader, b); close(done) }()
	return done
}

func TestPipeForwardsHalfClose(t *testing.T) {
	client, a := tcpPair(t)
	b, upstream := tcpPair(t)
	done := pipeAsync(a, b, a)

	client.Write([]byte("ping"))
	client.(*net.TCPConn).CloseWrite()
	if got, err := io.ReadAll(upstream); err != nil || string(got) != "ping" {
		t.Fatalf("upstream read %q, %v", got, err)
	}
	upstream.Write([]byte("pong"))
	upstream.Close()
	if got, err := io.ReadAll(client); err != nil || string(got) != "pong" {
		t.Fatalf("client read %q, %v", got, err)
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("pipe did not return")
	}
}

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("connection reset") }

// A failed copy can't be forwarded as a half-close: an idle upstream would
// keep the other direction blocked forever.
func TestPipeEndsBothDirectionsOnError(t *testing.T) {
	_, a := tcpPair(t)
	b, _ := tcpPair(t)
	select {
	case <-pipeAsync(a, b, failingReader{}):
	case <-time.After(2 * time.Second):
		t.Fatal("pipe kept waiting on an idle upstream after a failed copy")
	}
}

// An upstream that answers and closes (a container exiting under
// `docker run -i`) fails the client's next write with EPIPE. The part of its
// answer still queued in the agent must reach the client anyway.
func TestPipeDrainsTheAnswerOfAClosedUpstream(t *testing.T) {
	client, a := tcpPair(t)
	// Small TCP buffers keep most of the answer queued on the upstream side.
	client.(*net.TCPConn).SetReadBuffer(4096)
	a.(*net.TCPConn).SetWriteBuffer(4096)
	path := filepath.Join(t.TempDir(), "up.sock")
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	b, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	upstream, err := l.Accept()
	if err != nil {
		t.Fatal(err)
	}
	done := pipeAsync(a, b, a)

	client.Write([]byte("req"))
	request := make([]byte, 3)
	if _, err := io.ReadFull(upstream, request); err != nil {
		t.Fatal(err)
	}
	answer := bytes.Repeat([]byte("x"), 192<<10)
	upstream.Write(answer)
	upstream.Close() // nothing unread, so a clean close, not a reset
	time.Sleep(50 * time.Millisecond)
	client.Write([]byte("more")) // fails on the agent's side with EPIPE
	time.Sleep(50 * time.Millisecond)

	got, _ := io.ReadAll(client)
	if len(got) != len(answer) {
		t.Fatalf("client got %d of %d bytes", len(got), len(answer))
	}
	client.Close()
	<-done
}

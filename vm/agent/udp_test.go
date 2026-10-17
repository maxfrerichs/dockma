package main

import (
	"bufio"
	"bytes"
	"net"
	"testing"
	"time"
)

// The host's DatagramFrame tests assert the same bytes.
func TestDatagramFrameGolden(t *testing.T) {
	var b bytes.Buffer
	if err := writeDatagram(&b, []byte("hi!")); err != nil {
		t.Fatal(err)
	}
	if err := writeDatagram(&b, nil); err != nil {
		t.Fatal(err)
	}
	want := []byte{0x00, 0x03, 'h', 'i', '!', 0x00, 0x00}
	if !bytes.Equal(b.Bytes(), want) {
		t.Fatalf("got % x, want % x", b.Bytes(), want)
	}
	buf := make([]byte, 0xffff)
	got, err := readDatagram(&b, buf)
	if err != nil || string(got) != "hi!" {
		t.Fatalf("first frame: %q, %v", got, err)
	}
	got, err = readDatagram(&b, buf)
	if err != nil || len(got) != 0 {
		t.Fatalf("empty frame: %q, %v", got, err)
	}
	if err := writeDatagram(&b, make([]byte, 0x10000)); err == nil {
		t.Fatal("oversized datagram accepted")
	}
}

// echoServer answers each datagram with "echo:" + payload.
func echoServer(t *testing.T) *net.UDPConn {
	t.Helper()
	server, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		buf := make([]byte, 0xffff)
		for {
			n, peer, err := server.ReadFromUDP(buf)
			if err != nil {
				return
			}
			server.WriteToUDP(append([]byte("echo:"), buf[:n]...), peer)
		}
	}()
	return server
}

func TestRelayUDP(t *testing.T) {
	server := echoServer(t)
	defer server.Close()
	upstream, err := net.Dial("udp", server.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	host, guest := net.Pipe()
	done := make(chan struct{})
	go func() {
		relayUDP(guest, bufio.NewReader(guest), upstream, time.Minute)
		close(done)
	}()

	buf := make([]byte, 0xffff)
	for _, msg := range []string{"one", "two"} {
		if err := writeDatagram(host, []byte(msg)); err != nil {
			t.Fatal(err)
		}
		host.SetReadDeadline(time.Now().Add(5 * time.Second))
		got, err := readDatagram(host, buf)
		if err != nil || string(got) != "echo:"+msg {
			t.Fatalf("reply to %q: %q, %v", msg, got, err)
		}
	}

	host.Close()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("relay did not end after the host closed")
	}
}

func TestRelayUDPSurvivesRefusedPort(t *testing.T) {
	// A port with no listener: the kernel reports ICMP unreachable as
	// ECONNREFUSED on the connected socket.
	closed, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	addr := closed.LocalAddr().String()
	closed.Close()
	upstream, err := net.Dial("udp", addr)
	if err != nil {
		t.Fatal(err)
	}
	host, guest := net.Pipe()
	defer host.Close()
	done := make(chan struct{})
	go func() {
		relayUDP(guest, bufio.NewReader(guest), upstream, time.Minute)
		close(done)
	}()
	for i := 0; i < 3; i++ {
		if err := writeDatagram(host, []byte("x")); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	select {
	case <-done:
		t.Fatal("relay ended on a refused datagram")
	default:
	}
}

func TestRelayUDPIdleTimeout(t *testing.T) {
	server := echoServer(t)
	defer server.Close()
	upstream, err := net.Dial("udp", server.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	host, guest := net.Pipe()
	defer host.Close()
	done := make(chan struct{})
	go func() {
		relayUDP(guest, bufio.NewReader(guest), upstream, 100*time.Millisecond)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("idle relay did not end")
	}
}

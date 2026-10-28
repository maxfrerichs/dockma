package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"log"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/mdlayher/vsock"

	"github.com/dockma/dockma/vm/agent/internal/logchange"
)

// The host (AgentMessage in Swift) decodes these exact shapes.
func TestDockerMessageJSON(t *testing.T) {
	for ready, want := range map[bool]string{
		true:  `{"type":"docker","ready":true}`,
		false: `{"type":"docker","ready":false}`,
	} {
		got, err := json.Marshal(dockerMessage(ready))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want {
			t.Errorf("dockerMessage(%v) = %s; want %s", ready, got, want)
		}
	}
}

// handleControl sends hello and the full initial state, then only what
// changed.
func TestHandleControlSendsChangesOnly(t *testing.T) {
	host, agent := net.Pipe()
	defer host.Close()
	w := newPortWatcher()
	done := make(chan struct{})
	go func() {
		handleControl(agent, w, nil)
		close(done)
	}()

	lines := bufio.NewScanner(host)
	next := func() string {
		t.Helper()
		host.SetReadDeadline(time.Now().Add(5 * time.Second))
		if !lines.Scan() {
			t.Fatalf("no message: %v", lines.Err())
		}
		var m message
		if err := json.Unmarshal(lines.Bytes(), &m); err != nil {
			t.Fatal(err)
		}
		if m.Type == "hello" {
			return "hello"
		}
		got, _ := json.Marshal(m)
		return string(got)
	}

	for _, want := range []string{
		"hello",
		`{"type":"docker","ready":false}`,
		`{"type":"ports"}`, // omitempty drops an empty set; the host reads it as none
		`{"type":"watch"}`,
	} {
		if got := next(); got != want {
			t.Fatalf("got %s; want %s", got, want)
		}
	}
	w.setDockerReady(true)
	if got, want := next(), `{"type":"docker","ready":true}`; got != want {
		t.Fatalf("after ready: got %s; want %s", got, want)
	}
	w.publish([]forwardedPort{{Port: 8080, Transport: "tcp", Target: "127.0.0.1:8080"}})
	if got, want := next(), `{"type":"ports","ports":[{"port":8080,"transport":"tcp","target":"127.0.0.1:8080"}]}`; got != want {
		t.Fatalf("after publish: got %s; want %s", got, want)
	}
	w.update(func(s *watcherState) { s.Watch = []string{"/Users/me/src"} })
	if got, want := next(), `{"type":"watch","paths":["/Users/me/src"]}`; got != want {
		t.Fatalf("after watch: got %s; want %s", got, want)
	}
	// A files batch from the host is dropped without a forwarder and answers nothing.
	if _, err := host.Write([]byte(`{"type":"files","files":[{"op":"M","path":"/Users/me/src/a","mtimeNanos":1,"size":2}]}` + "\n")); err != nil {
		t.Fatal(err)
	}

	host.Close()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("handleControl did not return after the host closed")
	}
}

func TestOnlyTheHostIsAPeer(t *testing.T) {
	if !isHostPeer(&vsock.Addr{ContextID: vsock.Host, Port: 1234}) {
		t.Error("host refused")
	}
	for _, cid := range []uint32{vsock.Hypervisor, vsock.Local, 3, 42} {
		if isHostPeer(&vsock.Addr{ContextID: cid, Port: 1234}) {
			t.Errorf("CID %d admitted", cid)
		}
	}
	if isHostPeer(&net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}) {
		t.Error("non-vsock address admitted")
	}
}

func TestChangeLoggerSkipsRepeats(t *testing.T) {
	var out bytes.Buffer
	log.SetOutput(&out)
	defer log.SetOutput(os.Stderr)
	var errs logchange.Logger
	errs.Printf("fail %d", 1)
	errs.Printf("fail %d", 1)
	errs.Printf("fail %d", 2)
	errs.Reset()
	errs.Printf("fail %d", 2)
	if got := strings.Count(out.String(), "fail"); got != 3 {
		t.Fatalf("logged %d lines, want 3:\n%s", got, out.String())
	}
}

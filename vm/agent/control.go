package main

import (
	"bufio"
	"encoding/json"
	"log"
	"net"
	"os/exec"
	"slices"
	"sync"
	"syscall"
	"time"

	"github.com/mdlayher/vsock"

	"github.com/dockma/dockma/vm/agent/internal/fileevents"
	"github.com/dockma/dockma/vm/agent/internal/logchange"
)

// dialControl keeps a control connection to the host open. The host listens
// before the VM boots, so the retry only covers a host that went away.
func dialControl(ports *portWatcher, files *fileevents.Forwarder) {
	var errs logchange.Logger
	for {
		c, err := vsock.Dial(vsock.Host, controlPort, nil)
		if err != nil {
			errs.Printf("dial host vsock:%d: %v", controlPort, err)
		} else {
			errs.Reset()
			handleControl(c, ports, files)
		}
		time.Sleep(time.Second)
	}
}

// Control messages are single JSON objects per line.
type message struct {
	Type      string          `json:"type"`
	Version   string          `json:"version,omitempty"`
	Kernel    string          `json:"kernel,omitempty"`
	Ports     []forwardedPort `json:"ports,omitempty"`
	Ready     *bool           `json:"ready,omitempty"`
	UnixNanos int64           `json:"unixNanos,omitempty"`
	// Paths of a guest→host "watch": the host directories to watch for changes.
	Paths []string `json:"paths,omitempty"`
	// Files of a host→guest "files": changes made on the Mac.
	Files []fileevents.Event `json:"files,omitempty"`
}

// dockerMessage reports whether dockerd's API answers.
func dockerMessage(ready bool) message {
	return message{Type: "docker", Ready: &ready}
}

// handleControl serves one host connection. files is nil when the guest
// can't raise file events; the host's batches are then dropped.
func handleControl(c net.Conn, ports *portWatcher, files *fileevents.Forwarder) {
	defer c.Close()
	var writeMu sync.Mutex
	send := func(m message) error {
		data, _ := json.Marshal(m)
		writeMu.Lock()
		defer writeMu.Unlock()
		_, err := c.Write(append(data, '\n'))
		return err
	}

	var uts syscall.Utsname
	syscall.Uname(&uts)
	if send(message{Type: "hello", Version: version, Kernel: utsString(uts.Release[:])}) != nil {
		return
	}

	updates, cancel := ports.subscribe()
	defer cancel()
	go func() {
		var sent *watcherState
		for state := range updates {
			// Each message goes out first with the initial state, then only on change.
			if sent == nil || sent.DockerReady != state.DockerReady {
				if send(dockerMessage(state.DockerReady)) != nil {
					c.Close()
					return
				}
			}
			if sent == nil || !equalPorts(sent.Ports, state.Ports) {
				if send(message{Type: "ports", Ports: nonNil(state.Ports)}) != nil {
					c.Close()
					return
				}
			}
			if sent == nil || !slices.Equal(sent.Watch, state.Watch) {
				if send(message{Type: "watch", Paths: state.Watch}) != nil {
					c.Close()
					return
				}
			}
			sent = &state
		}
	}()

	scanner := bufio.NewScanner(c)
	for scanner.Scan() {
		var m message
		if err := json.Unmarshal(scanner.Bytes(), &m); err != nil {
			log.Printf("control: %v", err)
			continue
		}
		switch m.Type {
		case "settime":
			setTime(m.UnixNanos)
		case "files":
			if files != nil {
				files.Enqueue(m.Files)
			}
		case "shutdown":
			log.Print("shutdown requested by host")
			if err := exec.Command("poweroff").Run(); err != nil {
				log.Printf("poweroff: %v", err)
			}
		default:
			log.Printf("control: unknown message type %q", m.Type)
		}
	}
}

func nonNil(p []forwardedPort) []forwardedPort {
	if p == nil {
		return []forwardedPort{}
	}
	return p
}

func utsString(b []int8) string {
	out := make([]byte, 0, len(b))
	for _, c := range b {
		if c == 0 {
			break
		}
		out = append(out, byte(c))
	}
	return string(out)
}

// setTime steps the guest clock to the host's when they disagree by more than
// half a second, e.g. after the Mac slept.
func setTime(unixNanos int64) {
	if unixNanos <= 0 {
		return
	}
	host := time.Unix(0, unixNanos)
	if d := time.Since(host); d < 500*time.Millisecond && d > -500*time.Millisecond {
		return
	}
	tv := syscall.NsecToTimeval(unixNanos)
	if err := syscall.Settimeofday(&tv); err != nil {
		log.Printf("settimeofday: %v", err)
	}
}

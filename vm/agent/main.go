// dockma-agent runs inside the dockma VM. It serves four vsock ports for the
// macOS host: a byte proxy to dockerd's socket, a JSON-lines control channel,
// TCP tunnels for published container ports, and shell sessions.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/mdlayher/vsock"
)

const (
	version = "0.2.0"

	dockerPort  = 1024
	controlPort = 1025
	tunnelPort  = 1026
	shellPort   = 1027

	dockerSocket = "/var/run/docker.sock"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("dockma-agent: ")

	ports := newPortWatcher()
	go ports.run(context.Background())

	go serve(dockerPort, func(c net.Conn) {
		proxy(c, func() (net.Conn, error) { return net.Dial("unix", dockerSocket) })
	})
	go serve(tunnelPort, handleTunnel)
	go serve(shellPort, handleShell)
	serve(controlPort, func(c net.Conn) { handleControl(c, ports) })
}

// serve accepts vsock connections on port forever, one goroutine each.
func serve(port uint32, handle func(net.Conn)) {
	for {
		l, err := vsock.Listen(port, nil)
		if err != nil {
			log.Printf("listen vsock:%d: %v", port, err)
			time.Sleep(time.Second)
			continue
		}
		for {
			c, err := l.Accept()
			if err != nil {
				log.Printf("accept vsock:%d: %v", port, err)
				break
			}
			go handle(c)
		}
		l.Close()
	}
}

// proxy copies bytes both ways between c and a freshly dialled upstream,
// forwarding half-closes so hijacked docker connections (attach, exec) end
// cleanly.
func proxy(c net.Conn, dial func() (net.Conn, error)) {
	upstream, err := dial()
	if err != nil {
		log.Printf("dial upstream: %v", err)
		c.Close()
		return
	}
	pipe(c, upstream, c, upstream)
}

type halfCloser interface {
	CloseWrite() error
}

// pipe copies a→b and b→a; src readers may wrap the conns (e.g. buffered).
func pipe(a, b net.Conn, aReader, bReader io.Reader) {
	var wg sync.WaitGroup
	copyHalf := func(dst net.Conn, src io.Reader) {
		defer wg.Done()
		io.Copy(dst, src)
		if hc, ok := dst.(halfCloser); ok {
			hc.CloseWrite()
		} else {
			dst.Close()
		}
	}
	wg.Add(2)
	go copyHalf(b, aReader)
	go copyHalf(a, bReader)
	wg.Wait()
	a.Close()
	b.Close()
}

// parseTunnelHeader parses "tcp <host:port>\n", the first line of a tunnel
// connection, and returns the address to dial.
func parseTunnelHeader(line string) (string, error) {
	fields := strings.Fields(line)
	if len(fields) != 2 || fields[0] != "tcp" {
		return "", fmt.Errorf("malformed tunnel header %q", line)
	}
	if _, _, err := net.SplitHostPort(fields[1]); err != nil {
		return "", fmt.Errorf("malformed tunnel target %q: %w", fields[1], err)
	}
	return fields[1], nil
}

func handleTunnel(c net.Conn) {
	reader := bufio.NewReader(c)
	line, err := reader.ReadString('\n')
	if err != nil {
		c.Close()
		return
	}
	target, err := parseTunnelHeader(line)
	if err != nil {
		log.Print(err)
		c.Close()
		return
	}
	upstream, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		c.Close()
		return
	}
	pipe(c, upstream, reader, upstream)
}

// Control messages are single JSON objects per line.
type message struct {
	Type      string          `json:"type"`
	Version   string          `json:"version,omitempty"`
	Kernel    string          `json:"kernel,omitempty"`
	Ports     []ForwardedPort `json:"ports,omitempty"`
	UnixNanos int64           `json:"unixNanos,omitempty"`
}

func handleControl(c net.Conn, ports *portWatcher) {
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
		for set := range updates {
			if send(message{Type: "ports", Ports: nonNil(set)}) != nil {
				c.Close()
				return
			}
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

func nonNil(p []ForwardedPort) []ForwardedPort {
	if p == nil {
		return []ForwardedPort{}
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

// portWatcher tracks published ports via the Docker API and fans the current
// set out to subscribers (one per host control connection).
type portWatcher struct {
	mu      sync.Mutex
	current []ForwardedPort
	subs    map[chan []ForwardedPort]struct{}
	client  *http.Client
}

func newPortWatcher() *portWatcher {
	return &portWatcher{
		subs: map[chan []ForwardedPort]struct{}{},
		client: &http.Client{Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", dockerSocket)
			},
		}},
	}
}

// subscribe returns a channel that receives the current set immediately and
// every later change. The channel holds only the latest set.
func (w *portWatcher) subscribe() (<-chan []ForwardedPort, func()) {
	ch := make(chan []ForwardedPort, 1)
	w.mu.Lock()
	w.subs[ch] = struct{}{}
	ch <- w.current
	w.mu.Unlock()
	return ch, func() {
		w.mu.Lock()
		delete(w.subs, ch)
		w.mu.Unlock()
	}
}

func (w *portWatcher) publish(set []ForwardedPort) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if equalPorts(w.current, set) {
		return
	}
	w.current = set
	for ch := range w.subs {
		select {
		case <-ch:
		default:
		}
		ch <- set
	}
}

func equalPorts(a, b []ForwardedPort) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func (w *portWatcher) run(ctx context.Context) {
	var lastErr string
	for {
		err := w.watch(ctx)
		// dockerd not listening yet (boot, restart) is expected; other errors
		// are logged once each instead of every second.
		waiting := errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED)
		if err != nil && !waiting && !errors.Is(err, context.Canceled) && err.Error() != lastErr {
			log.Printf("port watcher: %v", err)
			lastErr = err.Error()
		}
		time.Sleep(time.Second)
	}
}

// watch relists containers whenever a container event arrives on the
// /events stream. Relisting keeps the logic simple and always consistent.
func (w *portWatcher) watch(ctx context.Context) error {
	filters := url.QueryEscape(`{"type":["container"]}`)
	req, _ := http.NewRequestWithContext(ctx, "GET", "http://docker/events?filters="+filters, nil)
	resp, err := w.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := w.relist(ctx); err != nil {
		return err
	}
	decoder := json.NewDecoder(resp.Body)
	for {
		var event struct {
			Action string `json:"Action"`
		}
		if err := decoder.Decode(&event); err != nil {
			return err
		}
		switch event.Action {
		case "start", "die", "destroy", "pause", "unpause", "restart":
			if err := w.relist(ctx); err != nil {
				return err
			}
		}
	}
}

func (w *portWatcher) relist(ctx context.Context) error {
	req, _ := http.NewRequestWithContext(ctx, "GET", "http://docker/containers/json", nil)
	resp, err := w.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("list containers: %s", resp.Status)
	}
	var containers []Container
	if err := json.NewDecoder(resp.Body).Decode(&containers); err != nil {
		return err
	}
	w.publish(PublishedPorts(containers))
	return nil
}

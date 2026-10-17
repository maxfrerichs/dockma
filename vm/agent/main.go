// dockma-agent runs inside the dockma VM. It serves three vsock ports for the
// macOS host: a byte proxy to dockerd's socket, TCP and UDP tunnels for
// published container ports, and shell sessions. It also dials the host's
// JSON-lines control port, so the host learns the moment the agent is up,
// and serves DNS for containers (dns.go). `dockma-agent daemon-config`
// writes dockerd's configuration instead (daemonconfig.go).
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
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/mdlayher/vsock"
)

const (
	version = "0.6.0"

	dockerPort  = 1024
	controlPort = 1025
	tunnelPort  = 1026
	shellPort   = 1027

	dockerSocket = "/var/run/docker.sock"
	// dataRoot is where the data disk is mounted.
	dataRoot = "/var/lib/docker"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("dockma-agent: ")
	if len(os.Args) > 1 && os.Args[1] == "daemon-config" {
		os.Exit(runDaemonConfig(os.Args[2:]))
	}
	raiseFileLimit()

	go serveDNS(newDNSForwarder())
	go trimDataDisk()
	ports := newPortWatcher()
	go ports.run(context.Background())

	go serve(dockerPort, func(c net.Conn) {
		proxy(c, func() (net.Conn, error) { return net.Dial("unix", dockerSocket) })
	})
	go serve(tunnelPort, handleTunnel)
	go serve(shellPort, handleShell)
	dialControl(ports)
}

// dialControl keeps a control connection to the host open. The host listens
// before the VM boots, so the retry only covers a host that went away.
func dialControl(ports *portWatcher) {
	var lastErr string
	for {
		c, err := vsock.Dial(vsock.Host, controlPort, nil)
		if err != nil {
			if err.Error() != lastErr {
				log.Printf("dial host vsock:%d: %v", controlPort, err)
				lastErr = err.Error()
			}
		} else {
			lastErr = ""
			handleControl(c, ports)
		}
		time.Sleep(time.Second)
	}
}

// raiseFileLimit lifts the descriptor limit from init's 1024/4096, since
// every tunnelled or proxied connection takes two.
func raiseFileLimit() {
	limit := syscall.Rlimit{Cur: 1 << 20, Max: 1 << 20}
	if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &limit); err != nil {
		log.Printf("raise file limit: %v", err)
	}
}

// trimDataDisk hands the data disk's free blocks back to the Mac every hour,
// starting a minute after boot: the image file on the host is sparse and
// otherwise only ever grows. Deleted images and containers free blocks that
// ext4 only reports with a discard.
func trimDataDisk() {
	time.Sleep(time.Minute)
	var lastErr string
	for {
		if err := exec.Command("mountpoint", "-q", dataRoot).Run(); err == nil {
			if out, err := exec.Command("fstrim", dataRoot).CombinedOutput(); err != nil {
				if msg := strings.TrimSpace(string(out)); msg != lastErr {
					log.Printf("fstrim %s: %v: %s", dataRoot, err, msg)
					lastErr = msg
				}
			} else {
				lastErr = ""
			}
		}
		time.Sleep(time.Hour)
	}
}

// isHostPeer reports whether a vsock connection comes from the macOS host.
// Anything else is a process in the VM, such as a container allowed to open
// AF_VSOCK sockets (privileged, or without seccomp), which must not get a
// root shell or the docker socket through the agent.
func isHostPeer(addr net.Addr) bool {
	a, ok := addr.(*vsock.Addr)
	return ok && a.ContextID == vsock.Host
}

// serve accepts vsock connections from the host on port forever, one
// goroutine each.
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
			if !isHostPeer(c.RemoteAddr()) {
				log.Printf("vsock:%d: refused connection from %v", port, c.RemoteAddr())
				c.Close()
				continue
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

// parseTunnelHeader parses "tcp <host:port>\n" or "udp <host:port>\n", the
// first line of a tunnel connection, and returns the network and the address
// to dial.
func parseTunnelHeader(line string) (network, target string, err error) {
	fields := strings.Fields(line)
	if len(fields) != 2 || (fields[0] != "tcp" && fields[0] != "udp") {
		return "", "", fmt.Errorf("malformed tunnel header %q", line)
	}
	if _, _, err := net.SplitHostPort(fields[1]); err != nil {
		return "", "", fmt.Errorf("malformed tunnel target %q: %w", fields[1], err)
	}
	return fields[0], fields[1], nil
}

// handleTunnel serves one tunnel connection: a TCP stream, or one UDP flow
// carried as datagram frames.
func handleTunnel(c net.Conn) {
	reader := bufio.NewReader(c)
	line, err := reader.ReadString('\n')
	if err != nil {
		c.Close()
		return
	}
	network, target, err := parseTunnelHeader(line)
	if err != nil {
		log.Print(err)
		c.Close()
		return
	}
	upstream, err := net.DialTimeout(network, target, 5*time.Second)
	if err != nil {
		c.Close()
		return
	}
	if network == "udp" {
		relayUDP(c, reader, upstream, udpIdleTimeout)
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
	Ready     *bool           `json:"ready,omitempty"`
	UnixNanos int64           `json:"unixNanos,omitempty"`
}

// dockerMessage reports whether dockerd's API answers.
func dockerMessage(ready bool) message {
	return message{Type: "docker", Ready: &ready}
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

// watcherState is what the port watcher fans out: the published ports and
// whether dockerd's API answers.
type watcherState struct {
	Ports       []ForwardedPort
	DockerReady bool
}

// portWatcher tracks published ports and dockerd's readiness via the Docker
// API and fans the current state out to subscribers (one per host control
// connection).
type portWatcher struct {
	mu      sync.Mutex
	current watcherState
	subs    map[chan watcherState]struct{}
	client  *http.Client
}

func newPortWatcher() *portWatcher {
	return &portWatcher{
		subs: map[chan watcherState]struct{}{},
		client: &http.Client{Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", dockerSocket)
			},
		}},
	}
}

// subscribe returns a channel that receives the current state immediately and
// every later change. The channel holds only the latest state. Cancelling
// closes it, which ends the subscriber's range loop.
func (w *portWatcher) subscribe() (<-chan watcherState, func()) {
	ch := make(chan watcherState, 1)
	w.mu.Lock()
	w.subs[ch] = struct{}{}
	ch <- w.current
	w.mu.Unlock()
	return ch, func() {
		w.mu.Lock()
		defer w.mu.Unlock()
		// update sends only under mu to channels still in subs.
		if _, ok := w.subs[ch]; ok {
			delete(w.subs, ch)
			close(ch)
		}
	}
}

// publish records the published ports.
func (w *portWatcher) publish(set []ForwardedPort) {
	w.update(func(s *watcherState) { s.Ports = set })
}

// setDockerReady records whether dockerd's API answers.
func (w *portWatcher) setDockerReady(ready bool) {
	w.update(func(s *watcherState) { s.DockerReady = ready })
}

// update applies change and, if the state differs, sends it to subscribers.
func (w *portWatcher) update(change func(*watcherState)) {
	w.mu.Lock()
	defer w.mu.Unlock()
	next := w.current
	change(&next)
	if next.DockerReady == w.current.DockerReady && equalPorts(next.Ports, w.current.Ports) {
		return
	}
	w.current = next
	for ch := range w.subs {
		select {
		case <-ch:
		default:
		}
		ch <- next
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
		// Armed before the attempt, so a socket created during it still
		// wakes the wait below.
		waiter, waiterErr := newFileWaiter(filepath.Dir(dockerSocket), filepath.Base(dockerSocket))
		if waiterErr != nil && waiterErr.Error() != lastErr {
			log.Printf("port watcher: %v", waiterErr)
			lastErr = waiterErr.Error()
		}
		err := w.watch(ctx, func() {
			// Only a failed attempt waits on it; an open stream can last
			// hours, and the watch would queue every file created meanwhile.
			if waiter != nil {
				waiter.close()
				waiter = nil
			}
		})
		w.setDockerReady(false)
		// dockerd not listening yet (boot, restart) is expected; other errors
		// are logged once each instead of every second.
		waiting := errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED)
		if err != nil && !waiting && !errors.Is(err, context.Canceled) && err.Error() != lastErr {
			log.Printf("port watcher: %v", err)
			lastErr = err.Error()
		}
		if waiting && waiter != nil {
			// dockerd creates its socket when it starts listening. The
			// timeout covers a create that raced the failed dial.
			waiter.wait(2 * time.Second)
		} else {
			time.Sleep(time.Second)
		}
		if waiter != nil {
			waiter.close()
		}
	}
}

// watch relists containers whenever a container event arrives on the
// /events stream. Relisting keeps the logic simple and always consistent.
// opened runs once the stream is open and dockerd's API answers.
func (w *portWatcher) watch(ctx context.Context, opened func()) error {
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
	// The event stream is open and a request succeeded: the API answers.
	w.setDockerReady(true)
	opened()
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

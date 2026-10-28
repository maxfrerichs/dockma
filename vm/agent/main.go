// dockma-agent runs inside the dockma VM. It serves three vsock ports for the
// macOS host: a byte proxy to dockerd's socket, TCP and UDP tunnels for
// published container ports, and shell sessions. It also dials the host's
// JSON-lines control port, so the host learns the moment the agent is up,
// and serves DNS for containers (internal/dns). Changes made on the Mac to
// watched bind mounts become inotify events in the guest (internal/fileevents).
// `dockma-agent daemon-config` writes dockerd's configuration instead
// (internal/daemonconfig).
package main

import (
	"context"
	"log"
	"net"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/dockma/dockma/vm/agent/internal/daemonconfig"
	"github.com/dockma/dockma/vm/agent/internal/dns"
	"github.com/dockma/dockma/vm/agent/internal/fileevents"
	"github.com/dockma/dockma/vm/agent/internal/logchange"
	"github.com/dockma/dockma/vm/agent/internal/relay"
	"github.com/dockma/dockma/vm/agent/internal/shell"
)

const (
	version = "0.7.1"

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
		os.Exit(daemonconfig.Run(os.Args[2:]))
	}
	raiseFileLimit()

	go dns.Serve(dns.NewForwarder())
	go trimDataDisk()
	ports := newPortWatcher()
	ports.share = fileevents.HomeShare()
	go ports.run(context.Background())
	files := fileevents.NewForwarder()

	go serve(dockerPort, func(c net.Conn) {
		relay.Proxy(c, func() (net.Conn, error) { return net.Dial("unix", dockerSocket) })
	})
	go serve(tunnelPort, relay.HandleTunnel)
	go serve(shellPort, shell.Handle)
	dialControl(ports, files)
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
	var errs logchange.Logger
	for {
		if err := exec.Command("mountpoint", "-q", dataRoot).Run(); err == nil {
			if out, err := exec.Command("fstrim", dataRoot).CombinedOutput(); err != nil {
				errs.Printf("fstrim %s: %v: %s", dataRoot, err, strings.TrimSpace(string(out)))
			} else {
				errs.Reset()
			}
		}
		time.Sleep(time.Hour)
	}
}

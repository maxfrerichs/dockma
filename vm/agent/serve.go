package main

import (
	"log"
	"net"
	"time"

	"github.com/mdlayher/vsock"
)

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
				// A persistent error mustn't spin listen and accept.
				time.Sleep(100 * time.Millisecond)
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

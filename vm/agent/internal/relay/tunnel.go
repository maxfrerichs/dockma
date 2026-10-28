package relay

import (
	"bufio"
	"fmt"
	"log"
	"net"
	"strings"
	"time"
)

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

// HandleTunnel serves one tunnel connection: a TCP stream, or one UDP flow
// carried as datagram frames.
func HandleTunnel(c net.Conn) {
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

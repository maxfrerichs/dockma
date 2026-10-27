package main

import (
	"net"
	"sort"
	"strconv"
	"strings"
)

// Container is the subset of Docker's GET /containers/json item the agent uses.
type Container struct {
	Ports  []ContainerPort  `json:"Ports"`
	Mounts []ContainerMount `json:"Mounts"`
}

// ContainerMount is one entry of a container's mount list.
type ContainerMount struct {
	Type   string `json:"Type"`
	Source string `json:"Source"`
}

// WatchedPaths returns the sources of bind mounts on the home share, which
// is mounted at share, sorted and without paths that lie below another one.
// The host watches these for changes made on the Mac.
func WatchedPaths(containers []Container, share string) []string {
	if share == "" {
		return nil
	}
	var paths []string
	for _, c := range containers {
		for _, m := range c.Mounts {
			if m.Type == "bind" && (m.Source == share || strings.HasPrefix(m.Source, share+"/")) {
				paths = append(paths, m.Source)
			}
		}
	}
	sort.Strings(paths)
	var kept []string
next:
	for _, p := range paths {
		// Not just the last kept path: "/a-c" sorts between "/a" and "/a/b".
		for _, k := range kept {
			if p == k || strings.HasPrefix(p, k+"/") {
				continue next
			}
		}
		kept = append(kept, p)
	}
	return kept
}

// ContainerPort is one entry of a container's port list.
type ContainerPort struct {
	IP          string `json:"IP"`
	PrivatePort int    `json:"PrivatePort"`
	PublicPort  int    `json:"PublicPort"`
	Type        string `json:"Type"`
}

// ForwardedPort is a published TCP or UDP port the host should listen on.
// Target is the guest address the agent dials for a tunnelled connection.
type ForwardedPort struct {
	Port      int    `json:"port"`
	Transport string `json:"transport"`
	Target    string `json:"target"`
}

// portKey identifies a host port; TCP and UDP ports with the same number are
// separate forwards.
type portKey struct {
	port      int
	transport string
}

// PublishedPorts returns one entry per published TCP or UDP host port, sorted
// by port and then transport. Other transports (sctp) are skipped. Wildcard
// bindings are dialled via loopback, where docker-proxy also listens; an IPv4
// target wins over IPv6 when both exist for a port.
func PublishedPorts(containers []Container) []ForwardedPort {
	byKey := map[portKey]string{}
	for _, c := range containers {
		for _, p := range c.Ports {
			if (p.Type != "tcp" && p.Type != "udp") || p.PublicPort == 0 {
				continue
			}
			key := portKey{port: p.PublicPort, transport: p.Type}
			host := dialHost(p.IP)
			if existing, ok := byKey[key]; ok && isIPv4(existing) {
				continue
			}
			byKey[key] = host
		}
	}
	ports := make([]ForwardedPort, 0, len(byKey))
	for key, host := range byKey {
		ports = append(ports, ForwardedPort{
			Port:      key.port,
			Transport: key.transport,
			Target:    net.JoinHostPort(host, strconv.Itoa(key.port)),
		})
	}
	sort.Slice(ports, func(i, j int) bool {
		if ports[i].Port != ports[j].Port {
			return ports[i].Port < ports[j].Port
		}
		return ports[i].Transport < ports[j].Transport
	})
	return ports
}

func dialHost(ip string) string {
	switch ip {
	case "", "0.0.0.0":
		return "127.0.0.1"
	case "::":
		return "::1"
	}
	return ip
}

func isIPv4(host string) bool {
	parsed := net.ParseIP(host)
	return parsed != nil && parsed.To4() != nil
}

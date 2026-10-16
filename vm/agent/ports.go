package main

import (
	"net"
	"sort"
	"strconv"
)

// Container is the subset of Docker's GET /containers/json item the agent uses.
type Container struct {
	Ports []ContainerPort `json:"Ports"`
}

// ContainerPort is one entry of a container's port list.
type ContainerPort struct {
	IP          string `json:"IP"`
	PrivatePort int    `json:"PrivatePort"`
	PublicPort  int    `json:"PublicPort"`
	Type        string `json:"Type"`
}

// ForwardedPort is a published TCP port the host should listen on. Target is
// the guest address the agent dials for a tunnelled connection.
type ForwardedPort struct {
	Port   int    `json:"port"`
	Target string `json:"target"`
}

// PublishedPorts returns one entry per published TCP host port, sorted by
// port. Wildcard bindings are dialled via loopback, where docker-proxy also
// listens; an IPv4 target wins over IPv6 when both exist for a port.
func PublishedPorts(containers []Container) []ForwardedPort {
	byPort := map[int]string{}
	for _, c := range containers {
		for _, p := range c.Ports {
			if p.Type != "tcp" || p.PublicPort == 0 {
				continue
			}
			host := dialHost(p.IP)
			if existing, ok := byPort[p.PublicPort]; ok && isIPv4(existing) {
				continue
			}
			byPort[p.PublicPort] = host
		}
	}
	ports := make([]ForwardedPort, 0, len(byPort))
	for port, host := range byPort {
		ports = append(ports, ForwardedPort{Port: port, Target: net.JoinHostPort(host, strconv.Itoa(port))})
	}
	sort.Slice(ports, func(i, j int) bool { return ports[i].Port < ports[j].Port })
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

package main

import "testing"

func TestParseTunnelHeader(t *testing.T) {
	cases := []struct {
		line, network, target string
		ok                    bool
	}{
		{"tcp 127.0.0.1:8080\n", "tcp", "127.0.0.1:8080", true},
		{"tcp [::1]:443\n", "tcp", "[::1]:443", true},
		{"udp 127.0.0.1:53\n", "udp", "127.0.0.1:53", true},
		{"udp [::1]:53\n", "udp", "[::1]:53", true},
		{"udp 127.0.0.1\n", "", "", false},
		{"sctp 127.0.0.1:9\n", "", "", false},
		{"tcp 127.0.0.1\n", "", "", false},
		{"tcp\n", "", "", false},
		{"", "", "", false},
	}
	for _, c := range cases {
		network, target, err := parseTunnelHeader(c.line)
		if (err == nil) != c.ok || network != c.network || target != c.target {
			t.Errorf("parseTunnelHeader(%q) = %q, %q, %v; want %q, %q, ok=%v",
				c.line, network, target, err, c.network, c.target, c.ok)
		}
	}
}

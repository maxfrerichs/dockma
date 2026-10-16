package main

import "testing"

func TestParseTunnelHeader(t *testing.T) {
	cases := []struct {
		line, want string
		ok         bool
	}{
		{"tcp 127.0.0.1:8080\n", "127.0.0.1:8080", true},
		{"tcp [::1]:443\n", "[::1]:443", true},
		{"udp 127.0.0.1:53\n", "", false},
		{"tcp 127.0.0.1\n", "", false},
		{"tcp\n", "", false},
		{"", "", false},
	}
	for _, c := range cases {
		got, err := parseTunnelHeader(c.line)
		if (err == nil) != c.ok || got != c.want {
			t.Errorf("parseTunnelHeader(%q) = %q, %v; want %q, ok=%v", c.line, got, err, c.want, c.ok)
		}
	}
}

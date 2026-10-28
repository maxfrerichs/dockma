// Package lease reads what the udhcpc hook writes under /run/dockma.
package lease

import (
	"net"
	"os"
	"strings"
)

// ReadIP reads an IP address from the first field of path; nil if missing.
func ReadIP(path string) net.IP {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return nil
	}
	return net.ParseIP(fields[0])
}

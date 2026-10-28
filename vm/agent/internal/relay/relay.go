// Package relay copies bytes between connections: the docker socket proxy and
// the TCP and UDP tunnels to published container ports.
package relay

import (
	"io"
	"log"
	"net"
	"sync"
)

// Proxy copies bytes both ways between c and a freshly dialled upstream,
// forwarding half-closes so hijacked docker connections (attach, exec) end
// cleanly.
func Proxy(c net.Conn, dial func() (net.Conn, error)) {
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

// failureRecorder notes whether a write failed, so a copy error can be told
// apart from a broken source.
type failureRecorder struct {
	io.Writer
	failed bool
}

func (w *failureRecorder) Write(p []byte) (int, error) {
	n, err := w.Writer.Write(p)
	w.failed = w.failed || err != nil
	return n, err
}

// pipe copies a→b and b→a; src readers may wrap the conns (e.g. buffered).
func pipe(a, b net.Conn, aReader, bReader io.Reader) {
	var wg sync.WaitGroup
	copyHalf := func(dst net.Conn, src io.Reader) {
		defer wg.Done()
		recorder := &failureRecorder{Writer: dst}
		if _, err := io.Copy(recorder, src); err != nil && !recorder.failed {
			// The source broke (a reset, not EOF): an idle peer would leave
			// the other direction blocked forever. A failed write instead
			// half-closes, so what the closed side sent still drains.
			a.Close()
			b.Close()
			return
		}
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

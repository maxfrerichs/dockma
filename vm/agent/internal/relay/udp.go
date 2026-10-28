package relay

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// udpIdleTimeout closes a UDP flow nobody has used for this long. The host
// expires flows after 90 s, docker-proxy's conntrack timeout, and closes the
// vsock connection; this longer backstop covers a host that never does.
const udpIdleTimeout = 180 * time.Second

// writeDatagram writes one datagram frame, [len u16 BE][payload], in a single
// Write so a frame is never interleaved or split by the writer.
func writeDatagram(w io.Writer, payload []byte) error {
	if len(payload) > 0xffff {
		return errors.New("datagram too large")
	}
	frame := make([]byte, 2+len(payload))
	binary.BigEndian.PutUint16(frame, uint16(len(payload)))
	copy(frame[2:], payload)
	_, err := w.Write(frame)
	return err
}

// readDatagram reads one datagram frame into buf, which must hold 65535
// bytes, and returns the payload.
func readDatagram(r io.Reader, buf []byte) ([]byte, error) {
	var header [2]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	n := int(binary.BigEndian.Uint16(header[:]))
	if _, err := io.ReadFull(r, buf[:n]); err != nil {
		return nil, err
	}
	return buf[:n], nil
}

// relayUDP carries datagram frames from the vsock connection c (read through
// reader, which may hold buffered bytes) to the connected UDP socket upstream,
// and upstream's datagrams back as frames. It returns once either side closes
// or the flow has been idle for idle.
func relayUDP(c net.Conn, reader io.Reader, upstream net.Conn, idle time.Duration) {
	var lastActive atomic.Int64
	touch := func() { lastActive.Store(time.Now().UnixNano()) }
	touch()
	var once sync.Once
	closeBoth := func() {
		once.Do(func() {
			c.Close()
			upstream.Close()
		})
	}
	defer closeBoth()

	go func() {
		defer closeBoth()
		buf := make([]byte, 0xffff)
		for {
			payload, err := readDatagram(reader, buf)
			if err != nil {
				return
			}
			touch()
			// A refused send (ICMP unreachable from an earlier datagram) is
			// ordinary UDP loss; only a closed socket ends the flow.
			if _, err := upstream.Write(payload); errors.Is(err, net.ErrClosed) {
				return
			}
		}
	}()

	buf := make([]byte, 0xffff)
	for {
		upstream.SetReadDeadline(time.Unix(0, lastActive.Load()).Add(idle))
		n, err := upstream.Read(buf)
		if err != nil {
			if errors.Is(err, syscall.ECONNREFUSED) {
				continue
			}
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() &&
				time.Since(time.Unix(0, lastActive.Load())) < idle {
				continue // host→guest traffic moved the deadline
			}
			return
		}
		touch()
		if writeDatagram(c, buf[:n]) != nil {
			return
		}
	}
}

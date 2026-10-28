package dns

import (
	"encoding/binary"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/net/ipv4"

	"github.com/dockma/dockma/vm/agent/internal/lease"
	"github.com/dockma/dockma/vm/agent/internal/logchange"
)

// The DNS forwarder answers host.docker.internal and gateway.docker.internal
// with the Mac's address on the VM network, as Docker Desktop does, and relays
// every other query unchanged to the DNS servers from the DHCP lease. The
// udhcpc hook points /etc/resolv.conf at the VM's own address, so containers
// get it through Docker's copy of resolv.conf (default bridge) or embedded
// DNS (other networks), and installs an nftables redirect from that address's
// port 53 to dnsListenAddress. The forwarder doesn't hold port 53 itself, so
// containers can still publish it or bind it with --network host.

const (
	dnsListenAddress = "0.0.0.0:10053"
	// Written by the udhcpc hook from the DHCP lease.
	gatewayFile     = "/run/dockma/gateway"
	upstreamDNSFile = "/run/dockma/upstream-dns"
	// Answers carry a short TTL: the gateway can change with a new lease.
	hostNameTTL = 60
	// Bounds concurrent forwarded queries; more are dropped, and clients retry.
	maxDNSInFlight = 256
	// Bounds open TCP connections; more are closed at once.
	maxDNSConnections = 64
	// How long one upstream gets before the next is tried. Resolvers in
	// containers give up after about 5 s in all.
	upstreamTimeout = 2 * time.Second
	// How long a TCP client may take to send a query, and to read a reply.
	tcpIdleTimeout = 10 * time.Second
	// How often the eth0 subnet that the client filter refuses is looked up.
	clientFilterRefresh = 5 * time.Second
)

// hostNames resolve to the Mac.
var hostNames = []string{"host.docker.internal.", "gateway.docker.internal."}

type Forwarder struct {
	// gateway returns the Mac's address, or nil if unknown.
	gateway func() net.IP
	// upstreams returns the servers to relay to, as host:port.
	upstreams func() []string
	// allows reports whether a client may query.
	allows  func(net.IP) bool
	timeout time.Duration
	// slots bounds queries in flight, tcpSlots open TCP connections.
	slots    chan struct{}
	tcpSlots chan struct{}

	mu sync.Mutex
	// preferred is the upstream that answered last, tried first.
	preferred string
}

func NewForwarder() *Forwarder {
	filter := &clientFilter{lookup: eth0Networks}
	f := &Forwarder{
		gateway:  func() net.IP { return lease.ReadIP(gatewayFile) },
		allows:   filter.allows,
		timeout:  upstreamTimeout,
		slots:    make(chan struct{}, maxDNSInFlight),
		tcpSlots: make(chan struct{}, maxDNSConnections),
	}
	f.upstreams = func() []string {
		var servers []string
		if data, err := os.ReadFile(upstreamDNSFile); err == nil {
			for _, field := range strings.Fields(string(data)) {
				if ip := net.ParseIP(field); ip != nil {
					servers = append(servers, net.JoinHostPort(ip.String(), "53"))
				}
			}
		}
		if len(servers) == 0 {
			if gw := f.gateway(); gw != nil {
				servers = append(servers, net.JoinHostPort(gw.String(), "53"))
			}
		}
		return servers
	}
	return f
}

// clientFilter admits queries from the VM itself and its containers, and
// refuses other machines on the VM's network (other VMs on the Mac), so the
// forwarder isn't an open resolver there. It looks the network up at most
// every clientFilterRefresh, not per query: each lookup is a netlink dump.
type clientFilter struct {
	// lookup returns the VM network's prefixes, each with the VM's address.
	lookup func() []*net.IPNet

	mu        sync.Mutex
	nets      []*net.IPNet
	refreshed time.Time
}

// allows reports whether src may query.
func (c *clientFilter) allows(src net.IP) bool {
	c.mu.Lock()
	if time.Since(c.refreshed) > clientFilterRefresh {
		c.nets = c.lookup()
		c.refreshed = time.Now()
	}
	nets := c.nets
	c.mu.Unlock()
	for _, n := range nets {
		if n.Contains(src) {
			return n.IP.Equal(src)
		}
	}
	return true
}

// eth0Networks returns eth0's IPv4 prefixes, each with the VM's address.
func eth0Networks() []*net.IPNet {
	iface, err := net.InterfaceByName("eth0")
	if err != nil {
		return nil
	}
	addrs, err := iface.Addrs()
	if err != nil {
		return nil
	}
	var nets []*net.IPNet
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil {
			nets = append(nets, n)
		}
	}
	return nets
}

// Serve serves UDP and TCP on dnsListenAddress until the process exits,
// binding again after a failure. A bind that keeps failing (a container
// holding the port) is logged once, not every second.
func Serve(f *Forwarder) {
	go func() {
		var errs logchange.Logger
		for {
			pc, err := net.ListenPacket("udp4", dnsListenAddress)
			if err != nil {
				errs.Printf("dns: listen udp: %v", err)
				time.Sleep(time.Second)
				continue
			}
			errs.Reset()
			f.serveUDP(pc)
			pc.Close()
			// A socket that fails right away mustn't spin.
			time.Sleep(time.Second)
		}
	}()
	var errs logchange.Logger
	for {
		l, err := net.Listen("tcp4", dnsListenAddress)
		if err != nil {
			errs.Printf("dns: listen tcp: %v", err)
			time.Sleep(time.Second)
			continue
		}
		errs.Reset()
		for {
			c, err := l.Accept()
			if err != nil {
				log.Printf("dns: accept: %v", err)
				time.Sleep(100 * time.Millisecond)
				break
			}
			select {
			case f.tcpSlots <- struct{}{}:
				go func() {
					defer func() { <-f.tcpSlots }()
					f.serveTCP(c)
				}()
			default:
				c.Close()
			}
		}
		l.Close()
	}
}

// serveUDP answers datagrams on pc until reading fails. Each reply leaves
// from the address its query was sent to: on the wildcard socket the kernel
// would otherwise pick the source by route (docker0's address for a container
// that asked the VM's eth0 address), and resolvers drop replies from an
// address they didn't ask.
func (f *Forwarder) serveUDP(pc net.PacketConn) {
	p := ipv4.NewPacketConn(pc)
	if err := p.SetControlMessage(ipv4.FlagDst, true); err != nil {
		log.Printf("dns: %v", err)
	}
	buf := make([]byte, 65535)
	for {
		n, cm, src, err := p.ReadFrom(buf)
		if err != nil {
			log.Printf("dns: read udp: %v", err)
			return
		}
		// The slot first: it's the cheap check that bounds a flood.
		select {
		case f.slots <- struct{}{}:
		default:
			continue
		}
		if addr, ok := src.(*net.UDPAddr); ok && !f.allows(addr.IP) {
			<-f.slots
			continue
		}
		query := append([]byte(nil), buf[:n]...)
		var replyFrom *ipv4.ControlMessage
		if cm != nil && cm.Dst != nil {
			replyFrom = &ipv4.ControlMessage{Src: cm.Dst}
		}
		go func() {
			defer func() { <-f.slots }()
			if reply := f.answer(query, false); reply != nil {
				p.WriteTo(reply, replyFrom, src)
			}
		}()
	}
}

// serveTCP answers length-prefixed queries on c until the client closes it
// or stays idle.
func (f *Forwarder) serveTCP(c net.Conn) {
	defer c.Close()
	if addr, ok := c.RemoteAddr().(*net.TCPAddr); ok && !f.allows(addr.IP) {
		return
	}
	for {
		c.SetDeadline(time.Now().Add(tcpIdleTimeout))
		query, err := readTCPMessage(c)
		if err != nil {
			return
		}
		reply := f.answer(query, true)
		if reply == nil {
			return
		}
		// The upstream exchange may have used up the read's deadline.
		c.SetDeadline(time.Now().Add(tcpIdleTimeout))
		if err := writeTCPMessage(c, reply); err != nil {
			return
		}
	}
}

// answer returns the reply to query: a local answer for the host names,
// otherwise the upstream's reply, or SERVFAIL when no upstream answered.
// Nil for a message that isn't a query.
func (f *Forwarder) answer(query []byte, overTCP bool) []byte {
	if reply, ok := localAnswer(query, f.gateway()); ok {
		return reply
	}
	var reply []byte
	var err error
	if overTCP {
		reply, err = f.exchangeTCP(query)
	} else {
		reply, err = f.exchangeUDP(query)
	}
	if err == nil {
		return reply
	}
	return serverFailure(query)
}

// localAnswer answers a query for one of hostNames with gateway's IPv4
// address (A) or no records (any other type), and reports whether it did.
func localAnswer(query []byte, gateway net.IP) ([]byte, bool) {
	gw4 := gateway.To4()
	if gw4 == nil {
		return nil, false
	}
	var p dnsmessage.Parser
	header, err := p.Start(query)
	if err != nil || header.Response {
		return nil, false
	}
	q, err := p.Question()
	if err != nil || q.Class != dnsmessage.ClassINET || !isHostName(q.Name.String()) {
		return nil, false
	}
	if _, err := p.Question(); !errors.Is(err, dnsmessage.ErrSectionDone) {
		return nil, false
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{
		ID:                 header.ID,
		Response:           true,
		OpCode:             header.OpCode,
		Authoritative:      true,
		RecursionDesired:   header.RecursionDesired,
		RecursionAvailable: true,
	})
	b.EnableCompression()
	if b.StartQuestions() != nil || b.Question(q) != nil || b.StartAnswers() != nil {
		return nil, false
	}
	if q.Type == dnsmessage.TypeA {
		rh := dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: hostNameTTL}
		if b.AResource(rh, dnsmessage.AResource{A: [4]byte(gw4)}) != nil {
			return nil, false
		}
	}
	reply, err := b.Finish()
	if err != nil {
		return nil, false
	}
	return reply, true
}

func isHostName(name string) bool {
	for _, h := range hostNames {
		if strings.EqualFold(name, h) {
			return true
		}
	}
	return false
}

// serverFailure is a SERVFAIL reply to query, or nil if query doesn't parse.
func serverFailure(query []byte) []byte {
	var p dnsmessage.Parser
	header, err := p.Start(query)
	if err != nil || header.Response {
		return nil
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{
		ID:                 header.ID,
		Response:           true,
		OpCode:             header.OpCode,
		RecursionDesired:   header.RecursionDesired,
		RecursionAvailable: true,
		RCode:              dnsmessage.RCodeServerFailure,
	})
	if b.StartQuestions() != nil {
		return nil
	}
	if q, err := p.Question(); err == nil {
		b.Question(q)
	}
	reply, err := b.Finish()
	if err != nil {
		return nil
	}
	return reply
}

// orderedUpstreams returns the upstreams with the one that answered last
// first, so a dead first server costs one timeout once, not on every query.
func (f *Forwarder) orderedUpstreams() []string {
	servers := f.upstreams()
	f.mu.Lock()
	preferred := f.preferred
	f.mu.Unlock()
	for i, s := range servers {
		if s == preferred && i > 0 {
			ordered := append([]string{s}, servers[:i]...)
			return append(ordered, servers[i+1:]...)
		}
	}
	return servers
}

// answered records server as the upstream to try first.
func (f *Forwarder) answered(server string) {
	f.mu.Lock()
	f.preferred = server
	f.mu.Unlock()
}

// exchangeUDP sends query to each upstream in turn and returns the first
// reply with the query's ID.
func (f *Forwarder) exchangeUDP(query []byte) ([]byte, error) {
	err := errors.New("no upstream DNS server")
	for _, server := range f.orderedUpstreams() {
		var reply []byte
		reply, err = f.exchangeUDPWith(server, query)
		if err == nil {
			f.answered(server)
			return reply, nil
		}
	}
	return nil, err
}

func (f *Forwarder) exchangeUDPWith(server string, query []byte) ([]byte, error) {
	c, err := net.DialTimeout("udp", server, f.timeout)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(f.timeout))
	if _, err := c.Write(query); err != nil {
		return nil, err
	}
	buf := make([]byte, 65535)
	for {
		n, err := c.Read(buf)
		if err != nil {
			return nil, err
		}
		// A late reply to an earlier query on a reused port isn't ours.
		if n >= 2 && len(query) >= 2 && buf[0] == query[0] && buf[1] == query[1] {
			return buf[:n], nil
		}
	}
}

// exchangeTCP relays query over TCP to the first upstream that accepts a
// connection, and over UDP if none does.
func (f *Forwarder) exchangeTCP(query []byte) ([]byte, error) {
	for _, server := range f.orderedUpstreams() {
		c, err := net.DialTimeout("tcp", server, f.timeout)
		if err != nil {
			continue
		}
		c.SetDeadline(time.Now().Add(f.timeout))
		reply, err := func() ([]byte, error) {
			defer c.Close()
			if err := writeTCPMessage(c, query); err != nil {
				return nil, err
			}
			return readTCPMessage(c)
		}()
		if err == nil {
			f.answered(server)
			return reply, nil
		}
	}
	return f.exchangeUDP(query)
}

// readTCPMessage reads one DNS message with its 2-byte length prefix.
func readTCPMessage(r io.Reader) ([]byte, error) {
	var length [2]byte
	if _, err := io.ReadFull(r, length[:]); err != nil {
		return nil, err
	}
	msg := make([]byte, binary.BigEndian.Uint16(length[:]))
	if _, err := io.ReadFull(r, msg); err != nil {
		return nil, err
	}
	return msg, nil
}

// writeTCPMessage writes msg with its 2-byte length prefix in one write.
func writeTCPMessage(w io.Writer, msg []byte) error {
	if len(msg) > 0xffff {
		return errors.New("dns message too long")
	}
	buf := binary.BigEndian.AppendUint16(make([]byte, 0, 2+len(msg)), uint16(len(msg)))
	_, err := w.Write(append(buf, msg...))
	return err
}

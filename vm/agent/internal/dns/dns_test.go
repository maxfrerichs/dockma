package dns

import (
	"net"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// buildQuery returns a query for name and type with the given ID.
func buildQuery(t *testing.T, id uint16, name string, typ dnsmessage.Type) []byte {
	t.Helper()
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: id, RecursionDesired: true})
	b.StartQuestions()
	b.Question(dnsmessage.Question{Name: dnsmessage.MustNewName(name), Type: typ, Class: dnsmessage.ClassINET})
	msg, err := b.Finish()
	if err != nil {
		t.Fatal(err)
	}
	return msg
}

// parseReply returns a reply's header and answers.
func parseReply(t *testing.T, reply []byte) (dnsmessage.Header, []dnsmessage.Resource) {
	t.Helper()
	var m dnsmessage.Message
	if err := m.Unpack(reply); err != nil {
		t.Fatal(err)
	}
	return m.Header, m.Answers
}

func TestLocalAnswerResolvesHostNames(t *testing.T) {
	gateway := net.ParseIP("192.168.64.1")
	reply, ok := localAnswer(buildQuery(t, 0x1234, "Host.Docker.Internal.", dnsmessage.TypeA), gateway)
	if !ok {
		t.Fatal("not answered locally")
	}
	header, answers := parseReply(t, reply)
	if header.ID != 0x1234 || !header.Response || !header.RecursionDesired || header.RCode != dnsmessage.RCodeSuccess {
		t.Errorf("header = %+v", header)
	}
	if len(answers) != 1 {
		t.Fatalf("answers = %v", answers)
	}
	if a, ok := answers[0].Body.(*dnsmessage.AResource); !ok || net.IP(a.A[:]).String() != "192.168.64.1" {
		t.Errorf("answer = %v", answers[0].Body)
	}

	// AAAA: the name exists, but has no IPv6 address.
	reply, ok = localAnswer(buildQuery(t, 7, "gateway.docker.internal.", dnsmessage.TypeAAAA), gateway)
	if !ok {
		t.Fatal("AAAA not answered locally")
	}
	if header, answers := parseReply(t, reply); header.RCode != dnsmessage.RCodeSuccess || len(answers) != 0 {
		t.Errorf("AAAA reply = %+v, %v", header, answers)
	}
}

func TestLocalAnswerLeavesOtherQueriesAlone(t *testing.T) {
	gateway := net.ParseIP("192.168.64.1")
	if _, ok := localAnswer(buildQuery(t, 1, "example.com.", dnsmessage.TypeA), gateway); ok {
		t.Error("answered example.com locally")
	}
	if _, ok := localAnswer(buildQuery(t, 1, "host.docker.internal.", dnsmessage.TypeA), nil); ok {
		t.Error("answered without a known gateway")
	}
	if _, ok := localAnswer([]byte{1, 2, 3}, gateway); ok {
		t.Error("answered garbage")
	}
}

// fakeUpstream answers every UDP and TCP query on 127.0.0.1 with a fixed A
// record, and returns its address.
func fakeUpstream(t *testing.T) string {
	t.Helper()
	pc, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })
	addr := pc.LocalAddr().String()
	l, err := net.Listen("tcp4", addr)
	if err != nil {
		t.Skipf("tcp port %s taken: %v", addr, err)
	}
	t.Cleanup(func() { l.Close() })
	reply := func(query []byte) []byte {
		var m dnsmessage.Message
		if err := m.Unpack(query); err != nil {
			return nil
		}
		m.Header.Response = true
		m.Answers = []dnsmessage.Resource{{
			Header: dnsmessage.ResourceHeader{Name: m.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 5},
			Body:   &dnsmessage.AResource{A: [4]byte{93, 184, 216, 34}},
		}}
		out, _ := m.Pack()
		return out
	}
	go func() {
		buf := make([]byte, 65535)
		for {
			n, src, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			pc.WriteTo(reply(buf[:n]), src)
		}
	}()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			if query, err := readTCPMessage(c); err == nil {
				writeTCPMessage(c, reply(query))
			}
			c.Close()
		}
	}()
	return addr
}

func testForwarder(upstreams ...string) *Forwarder {
	return &Forwarder{
		gateway:   func() net.IP { return net.ParseIP("192.168.64.1") },
		upstreams: func() []string { return upstreams },
		allows:    func(net.IP) bool { return true },
		timeout:   time.Second,
		slots:     make(chan struct{}, 4),
		tcpSlots:  make(chan struct{}, 4),
	}
}

func TestClientFilterRefusesOtherHostsOnTheVMNetwork(t *testing.T) {
	_, network, _ := net.ParseCIDR("192.168.64.0/24")
	lookups := 0
	filter := &clientFilter{lookup: func() []*net.IPNet {
		lookups++
		return []*net.IPNet{{IP: net.ParseIP("192.168.64.11").To4(), Mask: network.Mask}}
	}}
	for ip, want := range map[string]bool{
		"192.168.64.11": true,  // the VM itself
		"192.168.64.12": false, // another VM on the Mac
		"192.168.64.1":  false, // the Mac
		"172.17.0.2":    true,  // a container
		"127.0.0.1":     true,
	} {
		if got := filter.allows(net.ParseIP(ip)); got != want {
			t.Errorf("allows(%s) = %v, want %v", ip, got, want)
		}
	}
	if lookups != 1 {
		t.Errorf("looked the network up %d times, want once", lookups)
	}
}

func TestForwarderTriesTheLastWorkingUpstreamFirst(t *testing.T) {
	dead, _ := net.ListenPacket("udp4", "127.0.0.1:0")
	deadAddr := dead.LocalAddr().String()
	dead.Close()
	live := fakeUpstream(t)
	f := testForwarder(deadAddr, live)
	f.answer(buildQuery(t, 1, "example.com.", dnsmessage.TypeA), false)
	if got := f.orderedUpstreams(); len(got) != 2 || got[0] != live {
		t.Errorf("orderedUpstreams = %v, want %s first", got, live)
	}
}

func TestForwarderRelaysOtherNames(t *testing.T) {
	f := testForwarder(fakeUpstream(t))
	for _, overTCP := range []bool{false, true} {
		reply := f.answer(buildQuery(t, 0xbeef, "example.com.", dnsmessage.TypeA), overTCP)
		header, answers := parseReply(t, reply)
		if header.ID != 0xbeef || len(answers) != 1 {
			t.Errorf("tcp=%v: reply = %+v, %v", overTCP, header, answers)
		}
	}
}

func TestForwarderFailsOverAndReportsServerFailure(t *testing.T) {
	// A closed port first: the next upstream answers.
	dead, _ := net.ListenPacket("udp4", "127.0.0.1:0")
	deadAddr := dead.LocalAddr().String()
	dead.Close()
	f := testForwarder(deadAddr, fakeUpstream(t))
	if _, answers := parseReply(t, f.answer(buildQuery(t, 2, "example.com.", dnsmessage.TypeA), false)); len(answers) != 1 {
		t.Errorf("no answer after failing over: %v", answers)
	}

	f = testForwarder(deadAddr)
	header, _ := parseReply(t, f.answer(buildQuery(t, 3, "example.com.", dnsmessage.TypeA), false))
	if header.ID != 3 || header.RCode != dnsmessage.RCodeServerFailure {
		t.Errorf("header = %+v, want SERVFAIL", header)
	}
}

func TestServeUDPAndTCPEndToEnd(t *testing.T) {
	f := testForwarder(fakeUpstream(t))
	pc, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	go f.serveUDP(pc)
	c, err := net.Dial("udp4", pc.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	c.Write(buildQuery(t, 9, "host.docker.internal.", dnsmessage.TypeA))
	buf := make([]byte, 512)
	n, err := c.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	if header, answers := parseReply(t, buf[:n]); header.ID != 9 || len(answers) != 1 {
		t.Errorf("udp reply = %+v, %v", header, answers)
	}

	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go f.serveTCP(c)
		}
	}()
	tc, err := net.Dial("tcp4", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer tc.Close()
	tc.SetDeadline(time.Now().Add(5 * time.Second))
	// Two queries on one connection.
	for _, id := range []uint16{10, 11} {
		writeTCPMessage(tc, buildQuery(t, id, "example.com.", dnsmessage.TypeA))
		reply, err := readTCPMessage(tc)
		if err != nil {
			t.Fatal(err)
		}
		if header, answers := parseReply(t, reply); header.ID != id || len(answers) != 1 {
			t.Errorf("tcp reply = %+v, %v", header, answers)
		}
	}
}

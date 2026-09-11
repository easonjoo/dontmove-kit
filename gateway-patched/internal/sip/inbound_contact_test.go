package sip

import "testing"

// The upstream contactAddr fed the whole "user@host:port" string to
// ResolveUDPAddr, which always failed, so no inbound INVITE was ever sent
// to a registered client. These cases pin the fix.
func TestContactAddrStripsUserPart(t *testing.T) {
	cases := []struct {
		contact string
		want    string
	}{
		{"<sip:iphone@192.168.1.14:58999>;expires=300", "192.168.1.14:58999"},
		{"<sip:iphone@192.168.1.14:58999>", "192.168.1.14:58999"},
		{"<sip:192.168.1.14:58999>", "192.168.1.14:58999"},
		{"<sip:iphone@192.168.1.14:58999>;expires=0", "192.168.1.14:58999"},
	}
	for _, c := range cases {
		addr := contactAddr(c.contact)
		if addr == nil {
			t.Errorf("contactAddr(%q) = nil, want %s", c.contact, c.want)
			continue
		}
		if addr.String() != c.want {
			t.Errorf("contactAddr(%q) = %s, want %s", c.contact, addr.String(), c.want)
		}
	}
	if addr := contactAddr("garbage"); addr != nil {
		t.Errorf("contactAddr(garbage) = %v, want nil", addr)
	}
}

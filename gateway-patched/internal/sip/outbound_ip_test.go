package sip

import (
	"net"
	"strings"
	"testing"
)

// TestOutboundIPIsReachableFromAPhone locks in the fix for the CallKit
// "push_host" bug: the VoIP push used to advertise 127.0.0.1 (nasIP's fallback
// when Tailscale is absent), so YakPhone woke for a call whose URI pointed at
// the phone itself. It must never hand out a loopback, link-local, or
// proxy-tunnel address.
func TestOutboundIPIsReachableFromAPhone(t *testing.T) {
	server := &Server{}
	got := server.outboundIP()
	if got == "" {
		t.Fatal("outboundIP returned an empty address")
	}
	ip := net.ParseIP(got)
	if ip == nil {
		t.Fatalf("outboundIP = %q, not an IP", got)
	}
	if ip.IsLoopback() {
		t.Fatalf("outboundIP = %q, must not be loopback", got)
	}
	if ip.IsLinkLocalUnicast() {
		t.Fatalf("outboundIP = %q, must not be link-local", got)
	}
	// 198.18.0.0/15 is the benchmarking range TUN-based proxies hand out
	// (observed utun9 = 198.18.0.1 on this machine); a phone cannot reach it.
	if strings.HasPrefix(got, "198.18.") || strings.HasPrefix(got, "198.19.") {
		t.Fatalf("outboundIP = %q, must not be a proxy tunnel address", got)
	}
}

// TestPrivateLANIPSkipsTunnelsAndLinkLocal checks the interface walk directly.
func TestPrivateLANIPSkipsTunnelsAndLinkLocal(t *testing.T) {
	got := privateLANIP()
	if got == "" {
		t.Skip("no private LAN interface on this host")
	}
	ip := net.ParseIP(got)
	if ip == nil || !ip.IsPrivate() {
		t.Fatalf("privateLANIP = %q, want a private IPv4", got)
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		t.Fatalf("privateLANIP = %q, want a routable LAN address", got)
	}
}

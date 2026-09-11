package sip

import (
	"net"
	"testing"
)

// TestInboundRTPTargetIgnoresSDPAddress pins the second half of the
// "answered inbound calls are silent" bug. The dial path deliberately
// ignores the SDP c= line because YakPhone/baresip advertise an address that
// is unreachable from this host (tailnet peers talk over 100.x); the answer
// path trusted it and aimed RTP at an address that never replied, so the
// caller heard nothing. Only the media port may come from the SDP.
func TestInboundRTPTargetIgnoresSDPAddress(t *testing.T) {
	source := &net.UDPAddr{IP: net.ParseIP("100.64.0.9"), Port: 51060}
	sdpWithWanAddress := "v=0\r\n" +
		"o=- 1 1 IN IP4 203.0.113.7\r\n" +
		"s=-\r\n" +
		"c=IN IP4 203.0.113.7\r\n" +
		"t=0 0\r\n" +
		"m=audio 40000 RTP/AVP 0\r\n" +
		"a=rtpmap:0 PCMU/8000\r\n"

	cases := []struct {
		name   string
		remote *net.UDPAddr
		sdp    string
		want   string
	}{
		{
			name:   "packet source ip wins over the sdp address",
			remote: source,
			sdp:    sdpWithWanAddress,
			want:   "100.64.0.9:40000",
		},
		{
			name:   "media port still comes from the sdp",
			remote: &net.UDPAddr{IP: net.ParseIP("192.168.1.14"), Port: 5060},
			sdp:    sdpWithWanAddress,
			want:   "192.168.1.14:40000",
		},
		{
			name:   "sdp without a media line yields no target",
			remote: source,
			sdp:    "v=0\r\ns=-\r\n",
			want:   "",
		},
		{
			name:   "empty sdp yields no target",
			remote: source,
			sdp:    "",
			want:   "",
		},
		{
			name:   "nil remote yields no target",
			remote: nil,
			sdp:    sdpWithWanAddress,
			want:   "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := inboundRTPTarget(tc.remote, tc.sdp); got != tc.want {
				t.Fatalf("inboundRTPTarget() = %q, want %q", got, tc.want)
			}
		})
	}
}

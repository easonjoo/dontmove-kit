package at

import "testing"

// TestClccActiveMatchesDirection pins the regression behind "outbound audio
// works, answered inbound calls are silent": the answer path used to wait on
// +CLCC dir=0 only, so an inbound (mobile terminated) pickup — reported with
// dir=1 — was never recognised as active and the audio bridge only started
// after the whole deadline had elapsed.
func TestClccActiveMatchesDirection(t *testing.T) {
	// Answered inbound call: dir=1 (mobile terminated), state=0 (active).
	inboundActive := []string{
		`+CLCC: 1,1,0,0,0,"13800138000",129`,
		"OK",
	}
	// Answered outbound call: dir=0 (mobile originated), state=0.
	outboundActive := []string{
		`+CLCC: 1,0,0,0,0,"10010",129`,
		"OK",
	}
	// Ringing inbound call, not yet picked up: dir=1, state=4 (incoming).
	inboundRinging := []string{
		`+CLCC: 1,1,4,0,0,"13800138000",129`,
		"OK",
	}
	// Dialled call still alerting: dir=0, state=3.
	outboundAlerting := []string{
		`+CLCC: 1,0,3,0,0,"10010",129`,
		"OK",
	}
	noCall := []string{"OK"}

	cases := []struct {
		name  string
		lines []string
		dir   int
		want  bool
	}{
		{"outbound call matches outgoing", outboundActive, 0, true},
		{"outbound call is not an incoming answer", outboundActive, 1, false},
		{"inbound call matches incoming", inboundActive, 1, true},
		{"inbound call is not an outgoing answer", inboundActive, 0, false},
		{"inbound call matches any", inboundActive, -1, true},
		{"outbound call matches any", outboundActive, -1, true},
		{"ringing inbound is not active", inboundRinging, 1, false},
		{"ringing inbound is not active for any", inboundRinging, -1, false},
		{"alerting outbound is not active", outboundAlerting, 0, false},
		{"no call is never active", noCall, -1, false},
		{"malformed line is ignored", []string{"+CLCC: 1,x,0"}, -1, false},
		{"short line is ignored", []string{"+CLCC: 1,1"}, 1, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := clccActive(tc.lines, tc.dir); got != tc.want {
				t.Fatalf("clccActive(%q, %d) = %v, want %v", tc.lines, tc.dir, got, tc.want)
			}
		})
	}
}

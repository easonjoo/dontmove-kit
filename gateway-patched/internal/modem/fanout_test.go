package modem

import "testing"

// TestFanOutDeliversEveryEventToEverySink is the regression test for the
// inbound-call blackout: before FanOut existed, the API state machine and
// the SIP ringer shared one channel, so each inbound event reached exactly
// one of them and incoming calls silently did nothing half the time.
func TestFanOutDeliversEveryEventToEverySink(t *testing.T) {
	src := make(chan ModemEvent, 4)
	api := make(chan ModemEvent, 4)
	sip := make(chan ModemEvent, 4)

	done := make(chan struct{})
	go func() {
		FanOut(src, api, sip)
		close(done)
	}()

	src <- ModemEvent{Kind: "incoming", CallID: "c1", Peer: "13800138000"}
	src <- ModemEvent{Kind: "ended", CallID: "c1", Raw: "NO CARRIER"}
	close(src)
	<-done

	for _, tc := range []struct {
		name string
		ch   chan ModemEvent
	}{
		{"api", api},
		{"sip", sip},
	} {
		var got []ModemEvent
		for event := range tc.ch {
			got = append(got, event)
		}
		if len(got) != 2 {
			t.Fatalf("%s sink received %d events, want 2", tc.name, len(got))
		}
		if got[0].Kind != "incoming" || got[0].Peer != "13800138000" {
			t.Errorf("%s sink incoming event = %+v, want kind=incoming peer=13800138000", tc.name, got[0])
		}
		if got[1].Kind != "ended" {
			t.Errorf("%s sink second event = %+v, want kind=ended", tc.name, got[1])
		}
	}
}

// TestFanOutDoesNotStallOnSlowSink pins the drop-don't-block behaviour: a
// consumer that never drains its buffer must not wedge the modem reader,
// or a stalled HTTP handler would freeze the whole URC path.
func TestFanOutDoesNotStallOnSlowSink(t *testing.T) {
	src := make(chan ModemEvent, 8)
	full := make(chan ModemEvent, 1)
	live := make(chan ModemEvent, 8)

	done := make(chan struct{})
	go func() {
		FanOut(src, full, live)
		close(done)
	}()

	for i := 0; i < 5; i++ {
		src <- ModemEvent{Kind: "ended", CallID: "c1"}
	}
	close(src)
	<-done

	if n := len(live); n != 5 {
		t.Errorf("live sink buffered %d events, want 5", n)
	}
	if n := len(full); n != 1 {
		t.Errorf("full sink buffered %d events, want 1 (rest dropped)", n)
	}
}

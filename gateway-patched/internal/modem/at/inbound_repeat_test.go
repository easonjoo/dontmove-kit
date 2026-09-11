package at

import (
	"context"
	"testing"
	"time"

	"github.com/cellbridge/cellbridge/gateway/internal/modem"
)

func waitCallEvent(t *testing.T, adapter *Adapter, kind string) modem.ModemEvent {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case event := <-adapter.events:
			if event.Kind == kind {
				return event
			}
		case <-deadline:
			t.Fatalf("timed out waiting for %q event", kind)
			return modem.ModemEvent{}
		}
	}
}

// TestInboundCallRingsAgainAfterLocalHangup pins the fix for a silent
// inbound-call blackout: finishActive used to clear only `active`, leaving
// `incomingSent` set. The RING handler drops every RING while that flag is
// true (so a re-RING of the same call cannot open a second session), so once
// a call ended through a LOCAL hangup — the client declining, or the
// gateway's own ring timeout — every later inbound call was swallowed
// silently until the module happened to send NO CARRIER or the gateway was
// restarted.
func TestInboundCallRingsAgainAfterLocalHangup(t *testing.T) {
	port := &scriptedPort{}
	adapter := NewAdapter(NewClient(port))
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	adapter.HandleURC("RING")
	adapter.HandleURC(`+CLIP: "13800138000",129,,,,0`)
	first := waitCallEvent(t, adapter, "incoming")
	if first.Peer != "13800138000" {
		t.Fatalf("first incoming peer = %q, want 13800138000", first.Peer)
	}

	// The client declines (or the ring timeout fires): the gateway hangs the
	// cellular leg up itself, so no NO CARRIER ever arrives from the module.
	if err := adapter.Hangup(ctx, first.CallID); err != nil {
		t.Fatalf("hangup: %v", err)
	}
	waitCallEvent(t, adapter, "ended")

	// A genuinely new call must ring again.
	adapter.HandleURC("RING")
	adapter.HandleURC(`+CLIP: "10086",129,,,,0`)
	second := waitCallEvent(t, adapter, "incoming")
	if second.CallID == first.CallID {
		t.Errorf("second call reused call id %q, want a fresh one", second.CallID)
	}
	if second.Peer != "10086" {
		t.Errorf("second incoming peer = %q, want 10086", second.Peer)
	}
}

// TestIncomingKeepsLateClipNumber covers caller id arriving well after the
// RING: if a status poll owns the AT port when +CLIP shows up, the line is
// only dispatched once that poll finishes. A fixed short sleep expired first
// and the call surfaced as "unknown".
func TestIncomingKeepsLateClipNumber(t *testing.T) {
	adapter := NewAdapter(NewClient(&scriptedPort{}))

	adapter.HandleURC("RING")
	time.Sleep(500 * time.Millisecond)
	adapter.HandleURC(`+CLIP: "13800138000",129,,,,0`)

	event := waitCallEvent(t, adapter, "incoming")
	if event.Peer != "13800138000" {
		t.Fatalf("incoming peer = %q, want 13800138000", event.Peer)
	}
}

// TestRepeatedRingDoesNotOpenSecondSession is the counterweight: a cellular
// call re-rings every few seconds, and those repeats must NOT produce extra
// incoming events (which would blast the SIP client with parallel INVITEs).
func TestRepeatedRingDoesNotOpenSecondSession(t *testing.T) {
	adapter := NewAdapter(NewClient(&scriptedPort{}))

	adapter.HandleURC("RING")
	adapter.HandleURC(`+CLIP: "13800138000",129,,,,0`)
	waitCallEvent(t, adapter, "incoming")

	adapter.HandleURC("RING")
	adapter.HandleURC(`+CLIP: "13800138000",129,,,,0`)

	select {
	case event := <-adapter.events:
		t.Fatalf("re-RING produced an extra %q event", event.Kind)
	case <-time.After(700 * time.Millisecond):
	}
}

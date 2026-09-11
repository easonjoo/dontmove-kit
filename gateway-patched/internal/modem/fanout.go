package modem

import "log/slog"

// FanOut copies every event from src to each sink until src is closed,
// then closes every sink.
//
// A Go channel delivers each value to exactly one receiver, so a single
// modem event stream cannot be shared directly by several consumers. The
// gateway has two: the API call state machine (which persists the call and
// dispatches push) and the SIP server (which rings the registered phone).
// Handing both the raw channel made them steal events from each other — an
// inbound RING reached only whichever goroutine won the race, and whenever
// the API won, the phone never received an INVITE and incoming calls looked
// completely dead. Multiplexing here gives every consumer every event.
//
// Sinks are expected to be buffered; a full sink drops the event for that
// consumer rather than stalling the modem reader.
func FanOut(src <-chan ModemEvent, sinks ...chan ModemEvent) {
	for event := range src {
		if event.Kind == "incoming" || event.Kind == "ended" {
			slog.Info("modem call event fanned out", "kind", event.Kind, "call_id", string(event.CallID), "peer", event.Peer, "sinks", len(sinks))
		}
		for _, sink := range sinks {
			select {
			case sink <- event:
			default:
			}
		}
	}
	for _, sink := range sinks {
		close(sink)
	}
}

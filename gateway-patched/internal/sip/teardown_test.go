package sip

import (
	"net"
	"strings"
	"testing"

	"github.com/cellbridge/cellbridge/gateway/internal/modem"
)

// Regression tests for the 2026-09-10 report "对面挂断了，咱这边没反应，还在通话
// 中".
//
// The gateway released the bridge, the media port and the modem line when the
// cellular leg ended, but never told the SIP client: nothing in this file used
// to send a BYE, and endInboundCall only looked sessions up under
// "in-"+modem id, so an outbound session (keyed by the client's own Call-ID)
// was never even found. The phone stayed on the call screen after the audio
// had already stopped.

const clientInvite = "INVITE sip:10010@100.115.140.25 SIP/2.0\r\n" +
	"Via: SIP/2.0/UDP 100.86.10.78:51122;branch=z9hG4bK09fd;rport\r\n" +
	"From: <sip:iphone@100.86.10.78>;tag=cliTag99\r\n" +
	"To: <sip:10010@100.115.140.25>\r\n" +
	"Call-ID: 8f1a0b2c3d4e5f60\r\n" +
	"CSeq: 1 INVITE\r\n" +
	"Contact: <sip:iphone@100.86.10.78:51122>\r\n" +
	"Content-Type: application/sdp\r\n" +
	"Content-Length: 0\r\n\r\n"

// outboundPlan mirrors what handleInvite captures from the client's INVITE.
func outboundPlan() byePlan {
	return byePlan{
		remote:     &net.UDPAddr{IP: net.ParseIP("100.86.10.78"), Port: 51122},
		reqURI:     "sip:iphone@100.86.10.78:51122",
		from:       "<sip:10010@100.115.140.25>;tag=cbTag123",
		to:         "<sip:iphone@100.86.10.78>;tag=cliTag99",
		callID:     "8f1a0b2c3d4e5f60",
		inviteCSeq: 1,
		inviteReq:  clientInvite,
	}
}

// A call the far end hung up has to be closed at the client with a BYE that
// reproduces the dialog it established: same Call-ID, our From tag, the
// client's To tag, and a CSeq above anything the client sent.
func TestTeardownConnectedCallSendsBye(t *testing.T) {
	method, msg := teardownMessage("outbound", "active", "cbTag123", outboundPlan(), "100.115.140.25")
	if method != "BYE" {
		t.Fatalf("a connected call must be ended with BYE, got %q", method)
	}
	for _, want := range []string{
		"BYE sip:iphone@100.86.10.78:51122 SIP/2.0",
		"From: <sip:10010@100.115.140.25>;tag=cbTag123",
		"To: <sip:iphone@100.86.10.78>;tag=cliTag99",
		"Call-ID: 8f1a0b2c3d4e5f60",
		"CSeq: 2 BYE",
		"Via: SIP/2.0/UDP 100.115.140.25:5060",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("BYE missing %q\n--- got ---\n%s", want, msg)
		}
	}
}

// A phone that is still ringing for an abandoned inbound call needs a CANCEL,
// not a BYE: no dialog exists yet, and the CANCEL only matches the invitation
// on screen if it reuses the INVITE's Via branch and CSeq number.
func TestTeardownRingingInboundSendsCancel(t *testing.T) {
	plan := byePlan{
		remote:       &net.UDPAddr{IP: net.ParseIP("100.86.10.78"), Port: 54434},
		reqURI:       "sip:iphone@100.86.10.78:54434",
		from:         "<sip:15688525123@100.115.140.25>;tag=cb499fba6f",
		to:           "<sip:iphone@100.115.140.25>",
		callID:       "in-499fba6f-80cd-4269-b63b-2f4575dbc97a",
		inviteCSeq:   1,
		inviteBranch: "z9hG4bK499fba6f",
	}
	method, msg := teardownMessage("inbound", "init", "", plan, "100.115.140.25")
	if method != "CANCEL" {
		t.Fatalf("a still-ringing inbound call must be cancelled, got %q", method)
	}
	for _, want := range []string{
		"CANCEL sip:iphone@100.86.10.78:54434 SIP/2.0",
		"branch=z9hG4bK499fba6f",
		"CSeq: 1 CANCEL",
		"Call-ID: in-499fba6f-80cd-4269-b63b-2f4575dbc97a",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("CANCEL missing %q\n--- got ---\n%s", want, msg)
		}
	}
}

// An outbound call that never got answered must be answered with a final
// error, or the client keeps ringing until its own transaction timer expires
// (64s) for a call that is already dead.
func TestTeardownUnansweredOutboundSendsError(t *testing.T) {
	method, msg := teardownMessage("outbound", "dialing", "cbTag123", outboundPlan(), "100.115.140.25")
	if method != "480" {
		t.Fatalf("an unanswered outbound call must be answered with 480, got %q", method)
	}
	if !strings.HasPrefix(msg, "SIP/2.0 480 Temporarily Unavailable") {
		t.Errorf("unexpected status line: %s", strings.SplitN(msg, "\r\n", 2)[0])
	}
	// The response has to stay inside the INVITE transaction: same branch and
	// CSeq, and the tag pinned for this dialog.
	for _, want := range []string{
		"branch=z9hG4bK09fd",
		"CSeq: 1 INVITE",
		"To: <sip:10010@100.115.140.25>;tag=cbTag123",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("480 missing %q\n--- got ---\n%s", want, msg)
		}
	}
}

// A session with nothing to address (no captured dialog) must not produce a
// half-built message.
func TestTeardownWithoutDialogIsSilent(t *testing.T) {
	if method, msg := teardownMessage("inbound", "active", "", byePlan{}, ""); method != "" || msg != "" {
		t.Fatalf("a session without a dialog must produce nothing, got %q / %q", method, msg)
	}
}

// contactURI must fall back to the packet source when the client sent no
// usable Contact, so a teardown is never silently dropped.
func TestContactURIFallsBackToSourceAddress(t *testing.T) {
	remote := &net.UDPAddr{IP: net.ParseIP("100.86.10.78"), Port: 5060}
	if got := contactURI("", remote, "iphone"); got != "sip:iphone@100.86.10.78:5060" {
		t.Fatalf("empty Contact must fall back to the source address, got %q", got)
	}
	if got := contactURI("<sip:iphone@100.86.10.78:51122>;expires=300", remote, "iphone"); got != "sip:iphone@100.86.10.78:51122" {
		t.Fatalf("Contact parameters must be stripped, got %q", got)
	}
	if got := contactURI("", nil, "iphone"); got != "" {
		t.Fatalf("no Contact and no source must yield no URI, got %q", got)
	}
}

func newTestSession(id, direction, state string) *SIPCallSession {
	sess := NewSIPCallSession(id, "10010", direction, nil, nil, nil)
	sess.state = state
	return sess
}

// An outbound session is keyed by the client's Call-ID, which the modem has
// never seen. Matching on the modem id recorded while dialling is what finally
// lets a far-end hangup find it.
func TestSessionForModemEventMatchesOutboundByModemID(t *testing.T) {
	s := &Server{}
	sess := newTestSession("8f1a0b2c3d4e5f60", "outbound", "active")
	sess.SetModemCallID("call_a31a2f4730b9f3a1")
	s.sessions.Store(sess.ID, sess)

	got := s.sessionForModemEvent(modem.ModemEvent{Kind: "ended", CallID: "call_a31a2f4730b9f3a1", Raw: "NO CARRIER"})
	if got != sess {
		t.Fatal("a far-end hangup on an outbound call must find the session that owns that modem leg")
	}
}

// The HTTP dial path sets a logical call id, which the adapter substitutes into
// the event. The session carrying audio is then the only link left.
func TestSessionForModemEventFallsBackToActiveSession(t *testing.T) {
	s := &Server{}
	sess := newTestSession("8f1a0b2c3d4e5f60", "outbound", "active")
	sess.SetModemCallID("call_original")
	s.sessions.Store(sess.ID, sess)

	got := s.sessionForModemEvent(modem.ModemEvent{Kind: "ended", CallID: "client-supplied-id", Raw: "NO CARRIER"})
	if got != sess {
		t.Fatal("an event whose id was rewritten must still reach the session carrying audio")
	}
}

// Inbound sessions keep their direct lookup: the key is derived from the modem
// id, and that path worked before any of this.
func TestSessionForModemEventKeepsInboundLookup(t *testing.T) {
	s := &Server{}
	sess := newTestSession("in-c2ceb5a6-3a43-497a-b348-9097f66f3f62", "inbound", "active")
	s.sessions.Store(sess.ID, sess)

	got := s.sessionForModemEvent(modem.ModemEvent{Kind: "ended", CallID: "c2ceb5a6-3a43-497a-b348-9097f66f3f62"})
	if got != sess {
		t.Fatal("an inbound ended event must find its session by modem id")
	}
}

// The dangerous direction of the same logic: a "NO CARRIER" left over from the
// previous call must NOT abort a call that is only being dialled now.
func TestSessionForModemEventIgnoresStaleEventDuringDial(t *testing.T) {
	s := &Server{}
	dialing := newTestSession("9c9c9c9c9c9c9c9c", "outbound", "dialing")
	dialing.SetModemCallID("call_new")
	s.sessions.Store(dialing.ID, dialing)

	if got := s.sessionForModemEvent(modem.ModemEvent{Kind: "ended", CallID: "call_previous", Raw: "NO CARRIER"}); got != nil {
		t.Fatalf("a stale ended event must not tear down a call being dialled, matched %q", got.ID)
	}
}

// A session that already said goodbye must never be matched again: its BYE has
// been sent and its media is closed.
func TestSessionForModemEventSkipsEndedSessions(t *testing.T) {
	s := &Server{}
	ended := newTestSession("8f1a0b2c3d4e5f60", "outbound", "ended")
	ended.SetModemCallID("call_a31a2f4730b9f3a1")
	s.sessions.Store(ended.ID, ended)

	if got := s.sessionForModemEvent(modem.ModemEvent{Kind: "ended", CallID: "call_a31a2f4730b9f3a1"}); got != nil {
		t.Fatal("an already-ended session must not be matched a second time")
	}
}

// cseqNumber feeds the BYE's CSeq, which must exceed the client's INVITE.
func TestCSeqNumber(t *testing.T) {
	if got := cseqNumber("1 INVITE"); got != 1 {
		t.Fatalf("want 1, got %d", got)
	}
	if got := cseqNumber("314159 INVITE"); got != 314159 {
		t.Fatalf("want 314159, got %d", got)
	}
	if got := cseqNumber(""); got != 0 {
		t.Fatalf("empty CSeq must read as 0, got %d", got)
	}
}

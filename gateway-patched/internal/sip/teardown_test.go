package sip

import (
	"context"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

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

const clientInvite = "INVITE sip:10010@100.64.0.1 SIP/2.0\r\n" +
	"Via: SIP/2.0/UDP 100.86.10.78:51122;branch=z9hG4bK09fd;rport\r\n" +
	"From: <sip:iphone@100.86.10.78>;tag=cliTag99\r\n" +
	"To: <sip:10010@100.64.0.1>\r\n" +
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
		from:       "<sip:10010@100.64.0.1>;tag=cbTag123",
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
	method, msg := teardownMessage("outbound", "active", "cbTag123", outboundPlan(), "100.64.0.1")
	if method != "BYE" {
		t.Fatalf("a connected call must be ended with BYE, got %q", method)
	}
	for _, want := range []string{
		"BYE sip:iphone@100.86.10.78:51122 SIP/2.0",
		"From: <sip:10010@100.64.0.1>;tag=cbTag123",
		"To: <sip:iphone@100.86.10.78>;tag=cliTag99",
		"Call-ID: 8f1a0b2c3d4e5f60",
		"CSeq: 2 BYE",
		"Via: SIP/2.0/UDP 100.64.0.1:5060",
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
		from:         "<sip:13800138000@100.64.0.1>;tag=cb499fba6f",
		to:           "<sip:iphone@100.64.0.1>",
		callID:       "in-499fba6f-80cd-4269-b63b-2f4575dbc97a",
		inviteCSeq:   1,
		inviteBranch: "z9hG4bK499fba6f",
	}
	method, msg := teardownMessage("inbound", "init", "", plan, "100.64.0.1")
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
	method, msg := teardownMessage("outbound", "dialing", "cbTag123", outboundPlan(), "100.64.0.1")
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
		"To: <sip:10010@100.64.0.1>;tag=cbTag123",
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

// 2026-09-11: an incoming call rang on after the far end hung up. The CANCEL
// had been assembled from separate bookkeeping — its Request-URI came from the
// client's Contact — while the INVITE had been addressed to
// sip:<user>@<gateway>. RFC 3261 §9.1 requires the two to match, so the phone
// could not tie the CANCEL to the invitation on its screen and kept ringing.
func TestCancelMessageMirrorsTheInvite(t *testing.T) {
	invite := "INVITE sip:iphone@192.168.31.109 SIP/2.0\r\n" +
		"Via: SIP/2.0/UDP 192.168.31.109:5060;branch=z9hG4bK9c1f0d2a;rport\r\n" +
		"From: \"15688525123\" <sip:15688525123@192.168.31.109>;tag=cb9c1f0d2a\r\n" +
		"To: <sip:iphone@192.168.31.109>\r\n" +
		"Call-ID: in-9c1f0d2a\r\n" +
		"CSeq: 1 INVITE\r\n" +
		"Contact: <sip:cellbridge@192.168.31.109:5060>\r\n" +
		"Content-Length: 0\r\n\r\n"

	msg := cancelMessage(invite, "192.168.31.109")
	for _, want := range []string{
		"CANCEL sip:iphone@192.168.31.109 SIP/2.0",
		"branch=z9hG4bK9c1f0d2a",
		`From: "15688525123" <sip:15688525123@192.168.31.109>;tag=cb9c1f0d2a`,
		"To: <sip:iphone@192.168.31.109>",
		"Call-ID: in-9c1f0d2a",
		"CSeq: 1 CANCEL",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("CANCEL 缺少 %q\n--- got ---\n%s", want, msg)
		}
	}
}

// A phone woken by the VoIP push restarts its SIP stack and re-registers from a
// NEW source port, so the invitation it is showing can sit on a different
// address than the first one. Every invitation this gateway sent must be
// cancelled where it went — with the message it carried there.
func TestTeardownCancelsEveryInvitationSent(t *testing.T) {
	oldConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer oldConn.Close()
	newConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer newConn.Close()
	gwConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer gwConn.Close()

	inviteAddr := oldConn.LocalAddr().(*net.UDPAddr)
	reregAddr := newConn.LocalAddr().(*net.UDPAddr)

	invite := "INVITE sip:iphone@127.0.0.1 SIP/2.0\r\n" +
		"Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bK9c1f0d2a;rport\r\n" +
		"From: \"15688525123\" <sip:15688525123@127.0.0.1>;tag=cb9c1f0d2a\r\n" +
		"To: <sip:iphone@127.0.0.1>\r\n" +
		"Call-ID: in-9c1f0d2a\r\n" +
		"CSeq: 1 INVITE\r\n" +
		"Content-Length: 0\r\n\r\n"

	s := &Server{conn: gwConn}
	sess := newTestSession("in-9c1f0d2a", "inbound", "init")
	if !sess.RememberInvite(inviteAttempt{addr: inviteAddr, req: invite}) {
		t.Fatal("首次邀请应被记录")
	}
	// The retransmission that follows the phone's re-registration keeps the
	// branch (it is the same transaction) and only changes destination.
	if !sess.RememberInvite(inviteAttempt{addr: reregAddr, req: invite}) {
		t.Fatal("换端口后的重新投递应被记录")
	}
	sess.SetByePlan(byePlan{
		remote:   inviteAddr,
		reqURI:   "sip:iphone@" + inviteAddr.String(),
		callID:   "in-9c1f0d2a",
		username: "iphone",
		inviteReq: invite,
	})

	s.sendDialogTeardown(sess, "test")

	buf := make([]byte, 4096)
	for name, conn := range map[string]*net.UDPConn{"邀请时的地址": oldConn, "重新注册后的地址": newConn} {
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			t.Errorf("%s 没有收到任何 teardown: %v", name, err)
			continue
		}
		msg := string(buf[:n])
		// Request-URI 必须原样复用 INVITE 的值，而不是客户端 Contact。
		if want := "CANCEL sip:iphone@127.0.0.1 SIP/2.0"; !strings.HasPrefix(msg, want) {
			t.Errorf("%s: Request-URI 必须与 INVITE 相同\n want %q\n got  %q", name, want, strings.SplitN(msg, "\r\n", 2)[0])
		}
		if !strings.Contains(msg, "Call-ID: in-9c1f0d2a") {
			t.Errorf("%s: CANCEL 丢了对话框 Call-ID\n--- got ---\n%s", name, msg)
		}
		if !strings.Contains(msg, "CSeq: 1 CANCEL") {
			t.Errorf("%s: CANCEL 必须复用 INVITE 的 CSeq\n--- got ---\n%s", name, msg)
		}
	}
}

// Inviting the same contact twice rings the phone a second time instead of
// fixing anything, so only a contact that moved gets a second invitation.
func TestRememberInviteIgnoresRepeatAddresses(t *testing.T) {
	sess := newTestSession("in-7a10", "inbound", "init")
	first := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 5000}
	if !sess.RememberInvite(inviteAttempt{addr: first, req: "INVITE sip:iphone@127.0.0.1 SIP/2.0\r\n\r\n"}) {
		t.Fatal("首次邀请应被记录")
	}
	same := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 5000}
	if sess.RememberInvite(inviteAttempt{addr: same, req: "INVITE sip:iphone@127.0.0.1 SIP/2.0\r\n\r\n"}) {
		t.Error("同一地址不得被邀请两次")
	}
	if got := len(sess.InviteAttempts()); got != 1 {
		t.Errorf("记录数 = %d, want 1", got)
	}
}

// The sweep is what reaches a phone that came back on a new port after the push
// woke it: the invitation already on the wire went to the port it abandoned.
func TestReregisteredContactIsInvitedAgain(t *testing.T) {
	firstConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer firstConn.Close()
	secondConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer secondConn.Close()
	gwConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer gwConn.Close()

	firstAddr := firstConn.LocalAddr().(*net.UDPAddr)
	secondAddr := secondConn.LocalAddr().(*net.UDPAddr)
	reg := NewRegistrar()
	reg.Register("iphone", fmt.Sprintf("<sip:iphone@%s>;expires=300", firstAddr.String()), "UDP", 300)

	s := &Server{conn: gwConn, registrar: reg, ctx: context.Background()}
	s.ringClients(modem.ModemEvent{Kind: "incoming", CallID: modem.CallID("rereg-0001"), Peer: "15688525123"})

	buf := make([]byte, 4096)
	_ = firstConn.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, _, err := firstConn.ReadFromUDP(buf)
	if err != nil {
		t.Fatalf("首次 INVITE 未送达: %v", err)
	}
	first := string(buf[:n])

	// The phone restarts its SIP stack and comes back on a new port.
	reg.Register("iphone", fmt.Sprintf("<sip:iphone@%s>;expires=300", secondAddr.String()), "UDP", 300)

	_ = secondConn.SetReadDeadline(time.Now().Add(3 * time.Second))
	n, _, err = secondConn.ReadFromUDP(buf)
	if err != nil {
		t.Fatalf("换端口后没有收到重新投递的 INVITE: %v", err)
	}
	again := string(buf[:n])
	if !strings.HasPrefix(again, "INVITE ") {
		t.Errorf("新地址收到 %q，应为 INVITE", strings.SplitN(again, "\r\n", 2)[0])
	}
	// 必须是同一事务的重投（分支不变），否则手机上会出现第二通来电。
	for _, want := range []string{"Call-ID: in-rereg-0001", "branch=z9hG4bK"} {
		if !strings.Contains(again, want) {
			t.Errorf("重新投递的 INVITE 缺少 %q\n--- got ---\n%s", want, again)
		}
	}
	if !strings.Contains(first, viaBranchOf(again)) {
		t.Errorf("重新投递必须复用首次 INVITE 的 branch\n first: %q\n again: %q", first, again)
	}
	// 老地址不得再收到第二发。
	_ = firstConn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	if _, _, err := firstConn.ReadFromUDP(buf); err == nil {
		t.Error("已被邀请过的地址不应再次收到 INVITE")
	}
}

// The caller number has to survive the trip into the INVITE: iOS fills the
// lock-screen caller from the From display name, and a bare URI showed nothing.
func TestInboundCallerHeadersCarryTheNumber(t *testing.T) {
	extra, from := inboundCallerHeaders("15688525123", "192.168.31.109")
	if !strings.Contains(from, `"15688525123"`) {
		t.Errorf("From 缺少带引号的号码显示名: %q", from)
	}
	if !strings.Contains(from, "<sip:15688525123@192.168.31.109>") {
		t.Errorf("From 缺少号码 URI: %q", from)
	}
	for _, want := range []string{
		`P-Asserted-Identity: "15688525123" <sip:15688525123@192.168.31.109>`,
		`Remote-Party-ID: "15688525123" <sip:15688525123@192.168.31.109>`,
	} {
		if !strings.Contains(extra, want) {
			t.Errorf("缺少 %q\n--- got ---\n%s", want, extra)
		}
	}
}

// A call with no caller id must still produce a well-formed From: an empty
// header is rejected by some clients, which would drop the call entirely.
func TestInboundCallerHeadersWithoutNumberStayWellFormed(t *testing.T) {
	extra, from := inboundCallerHeaders("", "192.168.31.109")
	if extra != "" {
		t.Errorf("无号码时不应产生身份头，得到 %q", extra)
	}
	if !strings.HasPrefix(from, "<sip:unknown@192.168.31.109>") {
		t.Errorf("无号码时 From 应为 unknown URI，得到 %q", from)
	}
}

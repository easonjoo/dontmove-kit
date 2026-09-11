package sip

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/cellbridge/cellbridge/gateway/internal/modem"
	"github.com/google/uuid"
)

type Server struct {
	listenAddr string
	conn       *net.UDPConn
	registrar  *Registrar
	auth       *Auth
	modem      *modem.ActiveCallAdapter
	audio      modem.VoiceAudio
	events     <-chan modem.ModemEvent
	sessions   sync.Map
	pushToken  string
	sendSMS    func(ctx context.Context, to, body string) error
	ctx        context.Context
	cancel     context.CancelFunc

	// Linphone 锁屏来电推送（linphone_push.go）
	linphonePushKey string
	linphonePushURL string
	linphonePushFrom string
	pushMu          sync.Mutex
	pushRegs        map[string]pushParams

	// 已处理的 MESSAGE 事务（Call-ID|CSeq → 时间）。UDP 重传与首次完全同
	// 头，不去重就会把同一条聊天转发成多条真实短信（2026-09-11 实测：
	// 一条"你好啊"被 Linphone 重传两次、对面收到两条；打字指示 XML 同样翻倍）。
	seenMessages sync.Map
}

func NewServer(listenAddr string, registrar *Registrar, auth *Auth, modemCtl *modem.ActiveCallAdapter, audio modem.VoiceAudio) *Server {
	ctx, cancel := context.WithCancel(context.Background())
	return &Server{listenAddr: listenAddr, registrar: registrar, auth: auth, modem: modemCtl, audio: audio, ctx: ctx, cancel: cancel}
}

// AttachEvents wires modem events (RING etc) and the YakPhone push token
// from config so inbound cellular calls can ring the SIP client (§21).
func (s *Server) AttachEvents(events <-chan modem.ModemEvent, pushToken string) {
	s.events = events
	s.pushToken = pushToken
}

// SetLinphonePush 配置 Linphone 锁屏来电推送（FlexiAPI 的 x-api-key）。
// key 为空 = 功能关闭，行为与旧版完全一致。
func (s *Server) SetLinphonePush(key, url, from string) {
	s.linphonePushKey = key
	s.linphonePushURL = url
	s.linphonePushFrom = from
	if key != "" {
		slog.Info("linphonepush config",
			"key_prefix", keyPrefix(key), "key_len", len(key), "from", from)
		go logLinphoneEgressIP()
	}
}

// logLinphoneEgressIP 用推送专用的两个 HTTP 客户端各探测一次本机出口 IP。
// FlexiAPI 的 Key 与「生成时所在机器的出口 IP」强绑定（AuthenticateKey.php
// 校验 apiKey->ip == request->ip()），生成 Key 的浏览器优先走 IPv6，所以
// 两条栈的出口都要打出来，一眼就能看出 Key 该绑哪边、当前哪边变了。
func logLinphoneEgressIP() {
	// 用 Cloudflare 的 trace 服务（双栈 A+AAAA），返回体含 "ip=" 行，
	// 能真实反映该栈实际使用的出口地址族；ifconfig.me 之类只有 A 记录，
	// 会让 v6 栈也退化成 v4，看不出真相。
	for _, c := range []struct {
		name   string
		client *http.Client
	}{{"v6(default)", linphoneHTTPClient}, {"v4", linphoneHTTPClientV4}} {
		req, err := http.NewRequest(http.MethodGet, "https://cloudflare.com/cdn-cgi/trace", nil)
		if err != nil {
			continue
		}
		resp, err := c.client.Do(req)
		if err != nil {
			slog.Warn("linphonepush egress probe failed", "stack", c.name, "err", err)
			continue
		}
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		resp.Body.Close()
		ip := ""
		for _, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(line, "ip=") {
				ip = strings.TrimPrefix(line, "ip=")
			}
		}
		slog.Info("linphonepush egress ip", "stack", c.name, "ip", ip)
	}
}

// AttachSMS wires the SMS engine so SIP MESSAGE requests from the phone
// are delivered over the cellular modem (final architecture: SMS also
// routes through the NAS Gateway).
func (s *Server) AttachSMS(send func(ctx context.Context, to, body string) error) {
	s.sendSMS = send
}

// ForwardSMS delivers an inbound cellular SMS to every registered SIP client
// as a SIP MESSAGE (RFC 3428). Linphone renders these as chat messages, so
// the phone finally sees SIM texts it cannot otherwise receive — the SMS
// channel is cellular-only and never enters the SIP client on its own.
func (s *Server) ForwardSMS(peer, body string) {
	if s.conn == nil || s.registrar == nil || body == "" {
		return
	}
	caller := peer
	if caller == "" {
		caller = "unknown"
	}
	// SIP 头注入防护：peer 来自蜂窝 PDU，去掉可能破坏 From URI 的字符
	//（字母数字与 +-. 之外的一律剔除；字母号码类发件人如 "CHINAUNICOM" 也合法）。
	caller = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '+', r == '-', r == '.':
			return r
		}
		return -1
	}, caller)
	if caller == "" {
		caller = "unknown"
	}
	sent := 0
	for _, reg := range s.registrar.All() {
		remote := contactAddr(reg.Contact)
		if remote == nil {
			continue
		}
		local := s.localIPFor(remote)
		from := fmt.Sprintf("<sip:%s@%s>;tag=sms%d", caller, local, time.Now().UnixNano()%1000000)
		callID := fmt.Sprintf("sms-%d-%s", time.Now().UnixNano(), reg.Username)
		msg := fmt.Sprintf("MESSAGE sip:%s@%s SIP/2.0\r\nVia: SIP/2.0/UDP %s:5060;branch=z9hG4bKsms%d;rport\r\nMax-Forwards: 70\r\nFrom: %s\r\nTo: <sip:%s@%s>\r\nCall-ID: %s\r\nCSeq: 1 MESSAGE\r\nContact: <sip:cellbridge@%s:5060>\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\n\r\n%s",
			reg.Username, local, local, time.Now().UnixNano()%100000, from, reg.Username, local, callID, local, len(body), body)
		if _, err := s.conn.WriteToUDP([]byte(msg), remote); err != nil {
			slog.Warn("sms forward failed", "user", reg.Username, "peer", peer, "err", err)
			continue
		}
		sent++
	}
	if sent > 0 {
		slog.Info("sms forwarded to clients", "peer", peer, "clients", sent, "length", len(body))
	}
}

func (s *Server) Start(ctx context.Context) error {
	addr, err := net.ResolveUDPAddr("udp", s.listenAddr)
	if err != nil {
		return err
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		return err
	}
	s.conn = conn
	slog.Info("sip server listening", "addr", s.listenAddr)
	go s.readLoop()
	go s.inboundLoop()
	go s.ghostReaper()
	return nil
}

// ghostReaper clears cellular call contexts leaked by teardown races: a
// CANCEL/BYE processed while ATD is still dialling can lose the race against
// the module completing the call, leaving a connected call with no SIP
// session owning it. Runs only when no session is live, so ATH can never
// take down a call a client is actually on.
func (s *Server) ghostReaper() {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
		}
		s.maybeReapGhosts()
	}
}

// maybeReapGhosts runs one reap pass when no SIP session is live. Safe to
// call from anywhere; quiet when the modem is busy or unavailable.
func (s *Server) maybeReapGhosts() {
	if s.modem == nil {
		return
	}
	busy := false
	s.sessions.Range(func(_, v any) bool {
		if sess, ok := v.(*SIPCallSession); ok && sess.State() != "ended" {
			busy = true
			return false
		}
		return true
	})
	if busy {
		return
	}
	ctx, cancel := context.WithTimeout(s.ctx, 8*time.Second)
	defer cancel()
	if _, err := s.modem.ReapGhosts(ctx); err != nil {
		// Normal when the AT channel is wedged or mid-command; the next
		// tick retries.
		slog.Debug("ghost reap skipped", "err", err)
	}
}

func (s *Server) Stop(ctx context.Context) error {
	s.cancel()
	if s.conn != nil {
		_ = s.conn.Close()
	}
	s.sessions.Range(func(k, v interface{}) bool { _ = v.(*SIPCallSession).Hangup(); return true })
	return nil
}

func (s *Server) AddUser(username, password string) { s.auth.AddUser(username, password) }

func (s *Server) readLoop() {
	buf := make([]byte, 8192)
	for {
		n, remote, err := s.conn.ReadFromUDP(buf)
		if err != nil {
			select {
			case <-s.ctx.Done():
				return
			default:
			}
			continue
		}
		msg := string(buf[:n])
		// 信令轨迹：毫秒级时间戳 + 报文首行 + 远端端口。用来诊断
		// 「客户端秒挂」这类时序问题（RTP 噪声不含 SIP 首行样式，会被过滤）。
		if first, _, ok := strings.Cut(msg, "\r\n"); ok && (strings.HasPrefix(first, "SIP/2.0") ||
			strings.HasPrefix(first, "INVITE ") || strings.HasPrefix(first, "ACK ") ||
			strings.HasPrefix(first, "BYE ") || strings.HasPrefix(first, "CANCEL ") ||
			strings.HasPrefix(first, "REGISTER ") || strings.HasPrefix(first, "MESSAGE ") ||
			strings.HasPrefix(first, "OPTIONS ")) {
			at := time.Now().Format("15:04:05.000")
			cseq := parseHeader(msg, "CSeq")
			slog.Info("sip trace in", "at", at, "from", remote.String(), "line", first, "cseq", cseq, "callid", parseHeader(msg, "Call-ID"))
		}
		go s.handleMessage(msg, remote)
	}
}

// inboundLoop watches modem events. On an incoming cellular call (RING /
// +CLIP), it sends a SIP INVITE to every registered client (§21) and fires
// the YakPhone PushKit notification so the phone wakes even when the app
// is suspended.
func (s *Server) inboundLoop() {
	for {
		select {
		case <-s.ctx.Done():
			return
		case event, ok := <-s.events:
			if !ok {
				return
			}
			switch event.Kind {
			case "incoming":
				go s.ringClients(event)
			case "ended":
				go s.endCallByModem(event)
			}
		}
	}
}

// endCallByModem releases the session for a cellular call the network or the
// far end already tore down, in EITHER direction, and tells the SIP client
// about it.
//
// Two things were wrong here (observed 2026-09-10: "对面挂断了，咱这边还在通话
// 中"):
//
//   - Only inbound sessions were looked up, by "in-"+modem id. An outbound
//     session is keyed by the client's own Call-ID, so a far-end hangup on a
//     dialled call matched nothing: the PCM<->RTP bridge kept running on a
//     dead cellular leg and the phone stayed "in call" until the user hung up.
//   - Nothing was ever sent to the client. Releasing the bridge, the media
//     port and the modem line is all local, so the client's dialog stayed open
//     (the phone kept the call on screen indefinitely after the caller hung
//     up).
func (s *Server) endCallByModem(event modem.ModemEvent) {
	sess := s.sessionForModemEvent(event)
	if sess == nil {
		return
	}
	slog.Info("sip call ended by modem", "call", sess.ID, "dir", sess.Direction, "state", sess.State(), "raw", event.Raw)
	s.sessions.Delete(sess.ID)
	s.sendDialogTeardown(sess, "remote ended: "+event.Raw)
	_ = sess.Hangup()
}

// sessionForModemEvent maps a modem "ended" event back to the SIP dialog it
// belongs to. Inbound sessions are keyed "in-"+modem id, so the direct lookup
// covers them. For everything else the modem id recorded when the leg was set
// up is authoritative; the last resort is the single session that is actually
// carrying audio, which covers a modem id the adapter rewrote to a logical id
// (the HTTP dial path sets one) — V1 allows only one concurrent call, and a
// session that is merely dialling is never picked, so a stale event left over
// from the previous call cannot abort a call being set up.
func (s *Server) sessionForModemEvent(event modem.ModemEvent) *SIPCallSession {
	if v, ok := s.sessions.Load("in-" + string(event.CallID)); ok {
		if sess, ok := v.(*SIPCallSession); ok && sess.State() != "ended" {
			return sess
		}
	}
	var byModemID, byAudio *SIPCallSession
	s.sessions.Range(func(_, value any) bool {
		sess, ok := value.(*SIPCallSession)
		if !ok || sess.State() == "ended" {
			return true
		}
		if id := sess.ModemCallID(); id != "" && string(id) == string(event.CallID) {
			byModemID = sess
			return false
		}
		if byAudio == nil && sess.State() == "active" {
			byAudio = sess
		}
		return true
	})
	if byModemID != nil {
		return byModemID
	}
	return byAudio
}

func (s *Server) ringClients(event modem.ModemEvent) {
	peer := event.Peer
	if peer == "" {
		peer = "unknown"
	}
	// Key the session on the modem's physical call id. A cellular call
	// rings repeatedly (one RING every few seconds) and the upstream code
	// minted a brand new session per RING, blasting the client with
	// parallel INVITEs for a single incoming call.
	callID := "in-" + string(event.CallID)
	if callID == "in-" {
		callID = "in-" + uuid.NewString()[:12]
	}
	media, err := NewMediaSession("0.0.0.0:0")
	if err != nil {
		return
	}
	sess := NewSIPCallSession(callID, peer, "inbound", s.modem, s.audio, media)
	// Atomic claim: the Load guard alone cannot stop two RING events for
	// the same modem call from both passing it before either Stores.
	if !s.claimSession(callID, sess) {
		_ = media.Close()
		return
	}
	// Linphone 休眠时收不到 UDP INVITE：先推一把把它唤醒（弹 CallKit →
	// 重新 REGISTER）。前台客户端不受影响，第一轮 INVITE 就送到。
	s.wakeLinphoneClients(callID)
	// Branch and From-tag of this INVITE. They are derived from the call id
	// so that the CANCEL sent later (the far end gave up before the phone was
	// picked up) reuses the very branch the client is showing.
	shortID := strings.TrimPrefix(callID, "in-")
	if len(shortID) > 8 {
		shortID = shortID[:8]
	}
	branch := "z9hG4bK" + shortID
	// Address the phone can actually reach back on. nasIP() only knows the
	// tailnet (100.x) address and degrades to 127.0.0.1 without Tailscale, so
	// the VoIP push used to advertise sip:<peer>@127.0.0.1 — YakPhone then woke
	// for a CallKit call whose URI pointed at the phone itself. Prefer the
	// interface used to reach the registered client.
	reachable := ""
	// inviteRegistered invites every registration of this account that has not
	// been invited yet, and reports how many invitations went out this pass.
	//
	// A later pass is a RETRANSMISSION, not a new call: the branch, Call-ID and
	// CSeq of the first INVITE are kept, only the destination changes. That
	// distinction is what makes this safe. A client whose stack is still alive
	// recognises the branch as its own transaction and merely resends its
	// provisional response — no second call appears on screen. A client whose
	// stack the VoIP push restarted has no record of the branch and accepts a
	// brand-new invitation, which is exactly what puts a transaction on the new
	// port that the teardown CANCEL can match.
	inviteRegistered := func() int {
		sent := 0
		for _, reg := range s.registrar.All() {
			remote := contactAddr(reg.Contact)
			if remote == nil {
				continue
			}
			// The SDP c= line and Contact must advertise an address the
			// client can actually reach; derive it from the socket we use to
			// reach that very client.
			local := s.localIPFor(remote)
			if reachable == "" {
				reachable = local
			}
			inviteSDP := fmt.Sprintf("v=0\r\no=cellbridge 0 0 IN IP4 %s\r\ns=CellBridge\r\nc=IN IP4 %s\r\nt=0 0\r\nm=audio %d RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n", local, local, media.LocalAddr().Port)
			callerHdrs, callerFrom := inboundCallerHeaders(peer, local)
			invite := fmt.Sprintf("INVITE sip:%s@%s SIP/2.0\r\nVia: SIP/2.0/UDP %s:5060;branch=%s;rport\r\nFrom: %s;tag=cb%s\r\nTo: <sip:%s@%s>\r\nCall-ID: %s\r\nCSeq: 1 INVITE\r\nContact: <sip:cellbridge@%s:5060>\r\nMax-Forwards: 70\r\n%sContent-Type: application/sdp\r\nContent-Length: %d\r\n\r\n%s", reg.Username, local, local, branch, callerFrom, shortID, reg.Username, local, callID, local, callerHdrs, len(inviteSDP), inviteSDP)
			// Claim the address before sending it: a duplicate INVITE to the
			// same contact rings the phone again instead of fixing anything.
			if !sess.RememberInvite(inviteAttempt{addr: remote, req: invite}) {
				continue
			}
			// Remember where this invitation went, and the exact bytes of it.
			// The far end can give up while the phone is still ringing, and the
			// only way to stop that phone ringing is to CANCEL the invitation
			// it is showing — which must repeat this message byte for byte.
			// A later pickup overwrites this with the established dialog (see
			// acceptInbound). With several registered clients the last one
			// invited wins; V1 runs a single phone.
			sess.SetByePlan(byePlan{
				remote:       remote,
				reqURI:       contactURI(reg.Contact, remote, reg.Username),
				from:         fmt.Sprintf("%s;tag=cb%s", callerFrom, shortID),
				to:           fmt.Sprintf("<sip:%s@%s>", reg.Username, local),
				callID:       callID,
				inviteCSeq:   1,
				inviteBranch: branch,
				inviteReq:    invite,
				username:     reg.Username,
			})
			if _, err := s.conn.WriteToUDP([]byte(invite), remote); err != nil {
				slog.Warn("sip inbound invite failed", "user", reg.Username, "err", err)
				continue
			}
			sent++
			slog.Info("sip inbound invite sent", "user", reg.Username, "contact", remote.String(), "call", callID, "peer", peer, "attempt", len(sess.InviteAttempts()))
		}
		return sent
	}
	sent := inviteRegistered()
	if sent == 0 {
		slog.Warn("sip inbound invite unsent", "call", callID, "peer", peer, "reason", "no registered client reachable yet; sweeping the registrar")
	}
	// Keep watching the registration table until the call is answered or gone.
	// The VoIP push makes Linphone restart its SIP transport, and it comes back
	// from an entirely new source port (54865 → 61077 → 58100 within 40s on
	// 2026-09-11). The invitation sent to the previous port is unreachable by
	// then, so the CANCEL aimed at it matched nothing and the phone rang on
	// after the caller had hung up.
	go s.inviteReregisteredContacts(sess, inviteRegistered)
	if reachable == "" {
		reachable = s.outboundIP()
	}
	s.sendYakPush("sip:"+peer+"@"+reachable, "voip", "")
	slog.Info("sip inbound ringing", "call_id", callID, "peer", peer, "invites_sent", sent, "push_host", reachable)
	// Nobody picked up: release the cellular leg so the modem is not left
	// ringing forever (which would make every later dial fail with
	// ErrActiveCall until the gateway restarted).
	go func() {
		select {
		case <-time.After(inboundRingTimeout):
			if _, ok := s.sessions.Load(callID); ok {
				slog.Info("sip inbound ring timeout", "call", callID)
				s.sessions.Delete(callID)
				// Stop the client ringing too: without the CANCEL it keeps
				// showing an incoming call that no longer exists.
				s.sendDialogTeardown(sess, "ring timeout")
				_ = sess.Hangup()
			}
		case <-sess.ctx.Done():
		}
	}()
}

// inboundRingTimeout bounds how long an inbound call may ring before the
// gateway gives up and hangs up the cellular leg.
const inboundRingTimeout = 45 * time.Second

// inboundInviteSweep is how often the registrar is re-read while an inbound
// call rings, looking for a contact that appeared after the first invitation.
//
// A push-woken Linphone re-registers within a second or two of the push, and
// the invitation already on the wire was addressed to the port it has just
// abandoned, so this sweep is what actually puts a ringing call in front of
// the phone. It deliberately does not re-invite an address that was already
// invited — only a moved contact is re-aimed at.
const inboundInviteSweep = 600 * time.Millisecond

// inviteReregisteredContacts keeps inviting contacts that turn up while the
// call is still ringing, until the client answers or the call is torn down.
//
// The invitation is retransmitted verbatim, branch and all: a client whose
// stack survived recognises its own transaction and just resends its
// provisional response, while a client whose stack the push restarted accepts
// it as the invitation it is now waiting for. Either way the phone ends up
// with a transaction the teardown CANCEL can name.
func (s *Server) inviteReregisteredContacts(sess *SIPCallSession, invite func() int) {
	if invite == nil {
		return
	}
	deadline := time.Now().Add(inboundRingTimeout)
	for time.Now().Before(deadline) {
		select {
		case <-sess.ctx.Done():
			return
		case <-time.After(inboundInviteSweep):
		}
		// Once the client picked up there is a dialog, not an invitation; a
		// retransmission would only confuse it.
		if sess.State() != "init" {
			return
		}
		invite()
	}
}

// contactAddr extracts host:port from a SIP Contact header value.
func contactAddr(contact string) *net.UDPAddr {
	if i := strings.Index(contact, "sip:"); i >= 0 {
		rest := contact[i+4:]
		if j := strings.IndexAny(rest, ">;"); j >= 0 {
			rest = rest[:j]
		}
		// A Contact is user@host:port, but ResolveUDPAddr only accepts
		// host:port. The upstream code never stripped the user part, so
		// resolution always failed, contactAddr returned nil and every
		// inbound INVITE was skipped by the `if remote == nil { continue }`
		// guard below — the SIP client never rang on an incoming call.
		if at := strings.LastIndex(rest, "@"); at >= 0 {
			rest = rest[at+1:]
		}
		if addr, err := net.ResolveUDPAddr("udp", rest); err == nil {
			return addr
		}
	}
	return nil
}

// localIPFor returns the local address whose route reaches remote. The
// upstream nasIP() only looked for a tailnet (100.x) address and otherwise
// fell back to 127.0.0.1; a plain LAN client then received SDP with
// "c=IN IP4 127.0.0.1" and sent its RTP to itself, so the uplink was silent
// even though the downlink worked.
func (s *Server) localIPFor(remote *net.UDPAddr) string {
	if remote != nil && !remote.IP.IsUnspecified() {
		if conn, err := net.DialUDP("udp", nil, remote); err == nil {
			defer conn.Close()
			if la, ok := conn.LocalAddr().(*net.UDPAddr); ok && la.IP != nil && !la.IP.IsUnspecified() {
				return la.IP.String()
			}
		}
	}
	if ip := localTailnetIP(); ip != "" {
		return ip
	}
	return "127.0.0.1"
}

func (s *Server) handleMessage(msg string, remote *net.UDPAddr) {
	lines := strings.Split(msg, "\r\n")
	if len(lines) == 0 {
		return
	}
	first := lines[0]
	// Responses to the INVITEs the gateway itself sent out for inbound
	// cellular calls. The upstream code only parsed requests, so a client
	// picking up an inbound call was silently ignored: the phone rang,
	// the user answered, and nothing ever happened.
	if strings.HasPrefix(first, "SIP/2.0") {
		s.handleResponse(msg, remote)
		return
	}
	if strings.HasPrefix(first, "REGISTER") {
		s.handleRegister(msg, remote)
		return
	}
	if strings.HasPrefix(first, "INVITE") {
		s.handleInvite(msg, remote)
		return
	}
	if strings.HasPrefix(first, "ACK") {
		// ACK is part of the existing INVITE transaction; it is never answered.
		return
	}
	if strings.HasPrefix(first, "BYE") || strings.HasPrefix(first, "CANCEL") {
		s.handleAckBye(msg, remote, first)
		return
	}
	if strings.HasPrefix(first, "OPTIONS") {
		s.sendResponse(remote, msg, 200, "OK", "", "")
		return
	}
	if strings.HasPrefix(first, "MESSAGE") {
		s.handleMessageRequest(msg, remote)
		return
	}
}

// handleResponse processes responses to gateway-originated INVITEs, i.e.
// the client answering (or rejecting) an inbound cellular call.
func (s *Server) handleResponse(msg string, remote *net.UDPAddr) {
	lines := strings.Split(msg, "\r\n")
	if len(lines) == 0 {
		return
	}
	fields := strings.SplitN(lines[0], " ", 3)
	if len(fields) < 2 {
		return
	}
	code := 0
	fmt.Sscanf(fields[1], "%d", &code)
	callID := parseHeader(msg, "Call-ID")
	cseq := parseHeader(msg, "CSeq")
	if callID == "" {
		return
	}
	if strings.Contains(strings.ToUpper(cseq), "CANCEL") {
		// The client's verdict on our own CANCEL: 200 means it matched the
		// transaction and stopped ringing, 481 means there was nothing left to
		// match — a stack restarted by the VoIP push — and the phone rang on.
		// Logged before the session lookup because the session is usually gone
		// by then, and this line is the only visible evidence either way.
		slog.Info("sip cancel response", "call", callID, "code", code, "remote", remote.String())
		return
	}
	v, ok := s.sessions.Load(callID)
	if !ok {
		return
	}
	sess, ok := v.(*SIPCallSession)
	if !ok || sess.Direction != "inbound" {
		return
	}
	switch {
	case code == 100 || code == 180 || code == 183:
		// Provisional: the client is ringing. Logged deliberately — a bare
		// "phone did not ring" report is otherwise indistinguishable from
		// three very different causes. 180/183 proves YakPhone received the
		// INVITE and put the call on screen; only a 100 (or nothing at all)
		// means the app never presented it, which points at the app/OS side
		// (background suspension → needs the PushKit push) rather than at
		// the gateway.
		slog.Info("sip inbound provisional", "call", callID, "code", code, "remote", remote.String())
		return
	case code == 200 && strings.Contains(strings.ToUpper(cseq), "INVITE"):
		go s.acceptInbound(sess, msg, remote)
	case code >= 300:
		slog.Warn("sip inbound call declined", "call", callID, "code", code)
		s.sessions.Delete(callID)
		_ = sess.Hangup()
	}
}

// acceptInbound finishes an inbound call the client just answered: ACK the
// 200 OK, point RTP at the client, pick up the cellular leg (ATA) and start
// the PCM<->RTP bridge.
func (s *Server) acceptInbound(sess *SIPCallSession, msg string, remote *net.UDPAddr) {
	if !sess.beginAnswer() {
		return
	}
	callID := sess.ID
	s.sendACK(msg, remote, sess.Peer)
	// The client's 200 OK carries its own To-tag and usually its Contact.
	// Fold them into the stored dialog: the plan written when the INVITE went
	// out describes the invitation, not the established dialog, and the BYE
	// that ends a call the far end hung up has to address the latter.
	plan, _ := sess.ByePlan()
	plan.remote = remote
	if to := parseHeader(msg, "To"); to != "" {
		plan.to = to
	}
	if uri := contactURI(parseHeader(msg, "Contact"), remote, extractSIPUser(plan.to)); uri != "" {
		plan.reqURI = uri
	}
	sess.SetByePlan(plan)
	rtpTarget := inboundRTPTarget(remote, extractSDP(msg))
	if rtpTarget != "" {
		if err := sess.media.SetRemote(rtpTarget); err != nil {
			slog.Warn("sip inbound rtp target failed", "call", callID, "err", err)
		}
	} else {
		// MediaSession.WritePCMU silently drops every frame while the remote
		// is unset, so a missing SDP used to mean a silent call with no clue.
		slog.Warn("sip inbound answer had no usable SDP; RTP target unset", "call", callID, "remote", remote.String())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := sess.AnswerInbound(ctx); err != nil {
		slog.Warn("sip inbound answer failed", "call", callID, "err", err)
		s.sessions.Delete(callID)
		_ = sess.Hangup()
		return
	}
	slog.Info("sip inbound connected", "call", callID, "peer", sess.Peer, "rtp_remote", rtpTarget)
}

// inboundRTPTarget picks where to send RTP for a call the client just
// answered: the media port from the client's SDP, but always the packet's
// source IP. The dial path already ignored the SDP c= line — YakPhone /
// baresip advertise a WAN or LAN address there that is unreachable from
// this host (tailnet peers talk over 100.x) — while the answer path trusted
// it and aimed RTP at an address that never answered, so the caller heard
// nothing. Returns "" when the answer carried no usable media description.
func inboundRTPTarget(remote *net.UDPAddr, sdp string) string {
	if remote == nil {
		return ""
	}
	_, port := parseSDPRTP(sdp)
	if port == 0 {
		return ""
	}
	return fmt.Sprintf("%s:%d", remote.IP.String(), port)
}

// sendACK acknowledges the 200 OK that answered one of our inbound
// INVITEs. A SIP client keeps retransmitting the 200 until it sees the
// ACK, so omitting it makes the call drop a few seconds after pickup.
func (s *Server) sendACK(resp string, remote *net.UDPAddr, peer string) {
	from := parseHeader(resp, "From")
	to := parseHeader(resp, "To")
	callID := parseHeader(resp, "Call-ID")
	cseq := parseHeader(resp, "CSeq")
	seq := "1"
	if parts := strings.Fields(cseq); len(parts) > 0 {
		seq = parts[0]
	}
	user := extractSIPUser(to)
	if user == "" {
		user = extractSIPUser(from)
	}
	ack := fmt.Sprintf("ACK sip:%s@%s SIP/2.0\r\nVia: SIP/2.0/UDP %s:5060;branch=z9hG4bK%s;rport\r\nMax-Forwards: 70\r\nFrom: %s\r\nTo: %s\r\nCall-ID: %s\r\nCSeq: %s ACK\r\nContent-Length: 0\r\n\r\n", user, remote.String(), s.localIPFor(remote), uuid.NewString()[:12], from, to, callID, seq)
	if _, err := s.conn.WriteToUDP([]byte(ack), remote); err != nil {
		slog.Warn("sip ack failed", "call", callID, "err", err)
	}
}

func parseHeader(msg, name string) string {
	for _, line := range strings.Split(msg, "\r\n") {
		if strings.HasPrefix(strings.ToLower(line), strings.ToLower(name)+":") {
			return strings.TrimSpace(line[len(name)+1:])
		}
	}
	return ""
}

// handleMessageRequest delivers a SIP MESSAGE (from YakPhone, which is
// baresip-based and sends SMS as SIP instant messages) over the cellular
// modem via the attached SMS sender (§30). Responds 200 on acceptance,
// 500 when no SMS engine is wired or the modem rejects the submission.
//
// 三个防护（2026-09-11，起因是"对面收到乱码且重复两次"）：
//  1. 重传去重：Linphone 对 UDP MESSAGE 在 0.5s/1s/2s 处重发（网关要等
//     短信提交完才应答，必然超时），相同 Call-ID+CSeq 只提交一次短信；
//  2. 打字指示过滤：RFC 3994 <isComposing> XML 是客户端打字时自动发的
//     状态通知，转发成短信就是对面上百字符的乱码长文；
//  3. 先应答后提交：200 OK 立即回，短信提交放后台——客户端收不到及时
//     应答才会重传，从源头消灭重传。
func (s *Server) handleMessageRequest(msg string, remote *net.UDPAddr) {
	if s.sendSMS == nil {
		slog.Warn("sip message rejected", "reason", "SMS engine not attached")
		s.sendResponse(remote, msg, 500, "Server Error", "", "")
		return
	}
	// The destination is the Request-URI user part: MESSAGE sip:185xxx@host.
	requestURI := strings.Fields(msg)[1]
	destination := requestURI
	if index := strings.Index(requestURI, "@"); index > 0 {
		destination = strings.TrimPrefix(requestURI[:index], "sip:")
	}
	destination = strings.TrimLeft(destination, "+\x20")
	if destination == "" {
		slog.Warn("sip message rejected", "reason", "empty destination")
		s.sendResponse(remote, msg, 400, "Bad Request", "", "")
		return
	}
	// Message body follows the blank line (Content-Type: text/plain).
	body := ""
	if sections := strings.SplitN(msg, "\r\n\r\n", 2); len(sections) == 2 {
		body = strings.TrimSpace(sections[1])
	}
	if body == "" {
		slog.Warn("sip message rejected", "reason", "empty body", "to", destination)
		s.sendResponse(remote, msg, 400, "Bad Request", "", "")
		return
	}
	// 打字状态指示（RFC 3994）不是聊天内容，直接丢弃。
	if strings.Contains(body, "<isComposing") {
		slog.Info("sip message typing indicator dropped", "to", destination, "length", len(body))
		s.sendResponse(remote, msg, 200, "OK", "", "")
		return
	}
	// UDP 重传去重：同 Call-ID+CSeq 只提交一次。
	callID := parseHeader(msg, "Call-ID")
	cseq := parseHeader(msg, "CSeq")
	if callID != "" {
		key := callID + "|" + cseq
		if _, dup := s.seenMessages.LoadOrStore(key, time.Now()); dup {
			slog.Info("sip message retransmission dropped", "to", destination, "call", callID, "cseq", cseq)
			s.sendResponse(remote, msg, 200, "OK", "", "")
			return
		}
		// 顺手清理 2 分钟前的旧事务，防止 map 无限增长。
		cutoff := time.Now().Add(-2 * time.Minute)
		s.seenMessages.Range(func(k, v any) bool {
			if ts, ok := v.(time.Time); ok && ts.Before(cutoff) {
				s.seenMessages.Delete(k)
			}
			return true
		})
	}
	// 先回 200 再提交：让客户端立刻收到应答，不再触发 UDP 重传。
	// 提交失败只能记日志（对端已收到 200，无法再报错）。
	s.sendResponse(remote, msg, 200, "OK", "", "")
	go func() {
		ctx, cancel := context.WithTimeout(s.ctx, 30*time.Second)
		defer cancel()
		if err := s.sendSMS(ctx, destination, body); err != nil {
			slog.Warn("sip message send failed", "to", destination, "err", err)
			return
		}
		slog.Info("sip message sent", "to", destination, "length", len(body))
	}()
}

func (s *Server) handleRegister(msg string, remote *net.UDPAddr) {
	from := parseHeader(msg, "From")
	to := parseHeader(msg, "To")
	contact := parseHeader(msg, "Contact")
	expiresStr := parseHeader(msg, "Expires")
	username := extractSIPUser(to)
	if username == "" {
		username = extractSIPUser(from)
	}
	if s.auth.NeedsAuth(msg) {
		hdrs := "WWW-Authenticate: " + WWWAuthHeader(s.auth.Realm(), s.auth.Nonce()) + "\r\n"
		s.sendResponse(remote, msg, 401, "Unauthorized", hdrs, "")
		return
	}
	expires := 3600
	if expiresStr != "" {
		fmt.Sscanf(expiresStr, "%d", &expires)
	}
	if strings.Contains(contact, "expires=0") {
		expires = 0
	}
	s.registrar.Register(username, contact, "UDP", expires)
	// 记录/清除该注册的 RFC 8599 推送参数（Linphone 锁屏来电用）。
	// YakPhone 不带 pn-*，存不进去也无妨。
	if pp, ok := parsePushParams(contact); ok {
		s.storePushParams(username, pp, expires)
		slog.Info("sip register push params", "user", username, "provider", pp.Provider, "param", pp.Param, "prid_len", len(pp.Prid))
	} else if expires <= 0 {
		s.storePushParams(username, pushParams{}, 0)
	}
	s.sendResponse(remote, msg, 200, "OK", "Contact: "+contact+"\r\nExpires: "+fmt.Sprintf("%d", expires)+"\r\n", "")
	slog.Info("sip register", "user", username, "contact", contact, "expires", expires)
}

// reapStaleSessions hangs up and removes every lingering call session.
// Called before each outbound dial so a vanished client (no BYE ever
// arrives) cannot permanently pin the single QDC507 audio device.
func (s *Server) reapStaleSessions() {
	var stale []string
	s.sessions.Range(func(key, value any) bool {
		stale = append(stale, key.(string))
		return true
	})
	for _, id := range stale {
		if sess, ok := s.sessions.Load(id); ok {
			slog.Warn("reaping stale call session", "call", id)
			_ = sess.(*SIPCallSession).Hangup()
			s.sessions.Delete(id)
		}
	}
}

// claimSession atomically registers sess under callID and reports whether
// this caller won the race. It replaces the "Load guard ... Store much
// later" pattern, which is NOT atomic: an INVITE retransmission (T1=500ms)
// arriving inside the gap fell through the guard and created a second
// session for the same Call-ID.
//
// Why that mattered (observed 2026-09-10): both sessions reached
// voice.Bridge.Start, so two readLoops consumed the same QDC507 PCM
// capture stream. Each reader only saw a fraction of the frames, the
// 50-frame stats windows took ~2048ms instead of 1000ms (half rate), and
// the caller heard garbled, stuttering audio. The loser of the race never
// gets stored, so only the winner ever starts a bridge.
func (s *Server) claimSession(callID string, sess *SIPCallSession) bool {
	_, loaded := s.sessions.LoadOrStore(callID, sess)
	return !loaded
}

// handleInvite implements §20: invite -> 100 -> modem dial -> 180 -> wait
// cellular answer (PCM RUNNING) -> 200 OK. Retransmissions of the same
// Call-ID answer with current state, never a second dial.
func (s *Server) handleInvite(msg string, remote *net.UDPAddr) {
	from := parseHeader(msg, "From")
	to := parseHeader(msg, "To")
	peer := extractSIPUser(to)
	if peer == "" {
		peer = "unknown"
	}
	// 记录客户端 SDP offer 摘要：m= 行 + 加密/ICE 相关属性行。呼出秒断时
	// 由此判断是否媒体加密强制（offer 带 a=crypto/SAVP 而应答是纯 AVP，
	// Linphone 会 ACK 后立刻 BYE）或编解码不交集。
	if body := sdpOfferSummary(msg); body != "" {
		slog.Info("sip invite offer", "peer", peer, "content_type", parseHeader(msg, "Content-Type"), "sdp", body)
	}
	username := extractSIPUser(from)
	if _, ok := s.registrar.Get(username); !ok {
		s.sendResponse(remote, msg, 403, "Forbidden", "", "")
		return
	}
	callID := parseHeader(msg, "Call-ID")
	if callID == "" {
		callID = uuid.NewString()
	}
	if sess, ok := s.sessions.Load(callID); ok {
		existing := sess.(*SIPCallSession)
		hdrs := "Contact: <sip:cellbridge@" + s.localIPFor(remote) + ":5060>\r\nAllow: INVITE, ACK, BYE, CANCEL, OPTIONS\r\nContent-Type: application/sdp\r\n"
		if rx, tx := existing.media.Stats(); rx > 0 || tx > 0 || existing.State() == "active" {
			sdp := fmt.Sprintf("v=0\r\no=cellbridge 0 0 IN IP4 %s\r\ns=CellBridge\r\nc=IN IP4 %s\r\nt=0 0\r\nm=audio %d RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n", s.localIPFor(remote), s.localIPFor(remote), existing.media.LocalAddr().Port)
			s.sendResponseWithTag(remote, msg, 200, "OK", hdrs, sdp, existing.ToTag())
		} else {
			s.sendResponseWithTag(remote, msg, 180, "Ringing", "Contact: <sip:cellbridge@"+s.localIPFor(remote)+":5060>\r\n", "", existing.ToTag())
		}
		return
	}
	media, err := NewMediaSession("0.0.0.0:0")
	if err != nil {
		s.sendResponse(remote, msg, 500, "Server Error", "", "")
		return
	}
	clientSDP := extractSDP(msg)
	rtpIP, rtpPort := parseSDPRTP(clientSDP)
	// YakPhone/baresip may advertise its public WAN address in the SDP c= line;
	// inside the tailnet that address is unreachable. Always use the INVITE
	// packet's source IP with the SDP media port.
	if rtpPort != 0 {
		_ = media.SetRemote(fmt.Sprintf("%s:%d", remote.IP.String(), rtpPort))
	}

	s.sendResponse(remote, msg, 100, "Trying", "", "")
	// Reap any stale sessions BEFORE dialing. A client that vanished
	// (app killed, network drop) never sends BYE, so its bridge keeps
	// owning the QDC507 audio device forever and every later call dies
	// at bridge.Start with "QDC507 audio is already active for call…".
	// Observed 2026-09-06: a probe script that sent INVITE without BYE
	// blocked all subsequent calls.
	s.reapStaleSessions()
	// Pin the To-tag for this dialog. Every response we send for this INVITE
	// carries it, and so does the BYE that ends the call: the client matches
	// the dialog by Call-ID plus both tags, so a BYE with a fresh tag is
	// rejected as belonging to no dialog.
	localTag := uuid.NewString()[:8]
	sess := NewSIPCallSession(callID, peer, "outbound", s.modem, s.audio, media)
	sess.SetLocalTag(localTag)
	// Capture the dialog while the client's INVITE is in hand.
	sess.SetByePlan(byePlan{
		remote:     remote,
		reqURI:     contactURI(parseHeader(msg, "Contact"), remote, username),
		from:       to + ";tag=" + localTag,
		to:         from,
		callID:     callID,
		inviteCSeq: cseqNumber(parseHeader(msg, "CSeq")),
		inviteReq:  msg,
		username:   username,
	})
	// Claim the Call-ID BEFORE Dial(). Dial() rotates the QDC507 voice route
	// and issues ATD, which takes 2-9s; the retransmission guard at the top
	// of this function can only work once the session is in the map.
	// Storing it only after Dial() (as upstream did) left the whole dial
	// window open: a retransmitted INVITE created a SECOND session and a
	// second bridge for the same call, and the two readLoops split the
	// PCM capture stream -> half-rate, garbled audio.
	if !s.claimSession(callID, sess) {
		// Another handler already owns this Call-ID; answer provisionally
		// and leave it alone (it will send its own 200 OK when answered).
		slog.Info("sip invite duplicate suppressed", "call", callID, "peer", peer)
		tag := ""
		if v, ok := s.sessions.Load(callID); ok {
			tag = v.(*SIPCallSession).ToTag()
		}
		s.sendResponseWithTag(remote, msg, 180, "Ringing", "Contact: <sip:cellbridge@"+s.localIPFor(remote)+":5060>\r\n", "", tag)
		_ = media.Close()
		return
	}
	// Send 180 Ringing BEFORE dialing: the modem dial path includes a
	// per-call QDC507 route rotation (2-9s) + ATD. YakPhone shows the
	// caller "ringing" only after it receives 180, so a late 180 made
	// every call feel like "waits forever before ringing" after a NAS
	// reboot (observed 2026-09-06: dialing→180 gap ~9s on first call).
	// 180 is provisional and carries no SDP, so it is safe to send
	// before the cellular leg is ready.
	s.sendResponseWithTag(remote, msg, 180, "Ringing", "Contact: <sip:cellbridge@"+s.localIPFor(remote)+":5060>\r\n", "", sess.ToTag())
	if err := sess.Dial(); err != nil {
		slog.Warn("sip invite dial failed", "err", err)
		s.sendResponseWithTag(remote, msg, 500, "Server Error", "", "", sess.ToTag())
		s.sessions.Delete(callID)
		_ = media.Close()
		return
	}
	go func() {
		answerCtx, cancel := context.WithTimeout(context.Background(), answerTimeout)
		defer cancel()
		if err := sess.AwaitBridge(answerCtx); err != nil {
			slog.Warn("sip await bridge failed", "call", callID, "err", err)
			// Answer the client's INVITE even though the call never came up:
			// it was given a 180 and otherwise rings until its own
			// transaction timer expires (64s) for a call that is already dead.
			// A teardown triggered by the modem answers instead and leaves the
			// dialog to that path.
			if _, live := s.sessions.Load(callID); live {
				s.sendResponseWithTag(remote, msg, 480, "Temporarily Unavailable", "", "", sess.ToTag())
			}
			_ = sess.Hangup()
			s.sessions.Delete(callID)
			return
		}
		sdp := fmt.Sprintf("v=0\r\no=cellbridge 0 0 IN IP4 %s\r\ns=CellBridge\r\nc=IN IP4 %s\r\nt=0 0\r\nm=audio %d RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n", s.localIPFor(remote), s.localIPFor(remote), media.LocalAddr().Port)
		hdrs := "Contact: <sip:cellbridge@" + s.localIPFor(remote) + ":5060>\r\nAllow: INVITE, ACK, BYE, CANCEL, OPTIONS\r\nContent-Type: application/sdp\r\n"
		s.sendResponseWithTag(remote, msg, 200, "OK", hdrs, sdp, sess.ToTag())
		slog.Info("sip invite handled", "call", callID, "peer", peer, "rtp_remote", fmt.Sprintf("%s:%d", rtpIP, rtpPort))
	}()
}

func (s *Server) handleAckBye(msg string, remote *net.UDPAddr, first string) {
	callID := parseHeader(msg, "Call-ID")
	if callID == "" {
		s.sendResponse(remote, msg, 200, "OK", "", "")
		return
	}
	if v, ok := s.sessions.Load(callID); ok {
		sess := v.(*SIPCallSession)
		if strings.HasPrefix(first, "BYE") || strings.HasPrefix(first, "CANCEL") {
			// method/state/reason together tell apart the three teardown
			// causes: "CANCEL + state=init" = the phone aborted before
			// answering (declined, or it gave up while we were still
			// dialling the cellular leg), "BYE + state=active" = a normal
			// hangup after a connected call.
			slog.Info("sip bye received",
				"call", callID,
				"method", strings.Fields(first)[0],
				"state", sess.State(),
				"reason", parseHeader(msg, "Reason"))
			_ = sess.Hangup()
			s.sessions.Delete(callID)
			// 快速一次性收割：CANCEL/BYE 与蜂窝拨号竞态时，模块可能随后
			// 才完成应答，留下一具没人认领的"活尸"。3 秒后清一次，不等
			// 10 秒周期。
			go func() {
				select {
				case <-s.ctx.Done():
					return
				case <-time.After(3 * time.Second):
				}
				s.maybeReapGhosts()
			}()
		}
	}
	s.sendResponse(remote, msg, 200, "OK", "", "")
}

func (s *Server) nasIP() string {
	if ip := localTailnetIP(); ip != "" {
		return ip
	}
	return "127.0.0.1"
}

// outboundIP is the fallback reachable address when no SIP client is
// registered, so localIPFor has no peer to probe. This path matters: a
// suspended YakPhone eventually loses its registration, and then the VoIP push
// is the only way to reach it — with a useless host in caller_uri the CallKit
// call cannot be answered.
func (s *Server) outboundIP() string {
	if ip := localTailnetIP(); ip != "" {
		return ip
	}
	// Prefer a real private LAN address. A bare UDP dial can land on a
	// proxy/tunnel interface (observed: utun9 = 198.18.0.1 from a TUN-based
	// proxy), which the phone cannot reach.
	if ip := privateLANIP(); ip != "" {
		return ip
	}
	conn, err := net.Dial("udp", "8.8.8.8:53")
	if err != nil {
		return s.nasIP()
	}
	defer conn.Close()
	if addr, ok := conn.LocalAddr().(*net.UDPAddr); ok && addr.IP != nil && !addr.IP.IsUnspecified() {
		return addr.IP.String()
	}
	return s.nasIP()
}

// privateLANIP returns the first private IPv4 on an up, non-tunnel interface.
func privateLANIP() string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		name := iface.Name
		if strings.HasPrefix(name, "utun") || strings.HasPrefix(name, "tun") ||
			strings.HasPrefix(name, "tap") || strings.HasPrefix(name, "awdl") ||
			strings.HasPrefix(name, "llw") {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipNet.IP.To4()
			if ip4 == nil || !ip4.IsPrivate() {
				continue
			}
			return ip4.String()
		}
	}
	return ""
}

func (s *Server) sendResponse(remote *net.UDPAddr, req string, code int, reason, extraHeaders, body string) {
	s.sendResponseWithTag(remote, req, code, reason, extraHeaders, body, "")
}

// sendResponseWithTag is sendResponse with an explicit To-tag. A dialog's tag
// must be identical in the provisional and the final response to the same
// INVITE, and the BYE that later ends the call has to carry that very tag, so
// the response path pins one instead of minting a fresh tag per message.
func (s *Server) sendResponseWithTag(remote *net.UDPAddr, req string, code int, reason, extraHeaders, body, tag string) {
	resp := buildResponse(req, code, reason, extraHeaders, body, tag)
	if _, err := s.conn.WriteToUDP([]byte(resp), remote); err != nil {
		slog.Warn("sip response failed", "code", code, "err", err)
		return
	}
	slog.Info("sip trace out", "at", time.Now().Format("15:04:05.000"), "to", remote.String(), "line", fmt.Sprintf("SIP/2.0 %d %s", code, reason), "cseq", parseHeader(req, "CSeq"), "callid", parseHeader(req, "Call-ID"))
}

// buildResponse renders a SIP response to req. An empty tag mints a fresh
// one; a request whose To header already carries a tag keeps it.
func buildResponse(req string, code int, reason, extraHeaders, body, tag string) string {
	callID := parseHeader(req, "Call-ID")
	from := parseHeader(req, "From")
	to := parseHeader(req, "To")
	via := parseHeader(req, "Via")
	cseq := parseHeader(req, "CSeq")
	if tag == "" {
		tag = ";tag=" + uuid.NewString()[:8]
	}
	if strings.Contains(to, "tag=") {
		tag = ""
	}
	return fmt.Sprintf("SIP/2.0 %d %s\r\nVia: %s\r\nFrom: %s\r\nTo: %s%s\r\nCall-ID: %s\r\nCSeq: %s\r\n%sContent-Length: %d\r\n\r\n%s", code, reason, via, from, to, tag, callID, cseq, extraHeaders, len(body), body)
}

// teardownRepeatDelay spaces the duplicate teardown sent to each target.
// UDP has no retransmission of its own, and the phone this is aimed at is
// typically mid-reconnect (woken by a VoIP push seconds earlier), so a single
// lost datagram means the phone keeps ringing for a call nobody is on.
const teardownRepeatDelay = 200 * time.Millisecond

// sendDialogTeardown tells the SIP client that a call the modem has already
// released is over. Nothing else in this gateway ever sends a BYE, so a
// far-end hangup used to leave the client's dialog open forever: the phone
// stayed "in call" although the audio had stopped.
//
// The teardown is sent to every address the dialog's account could currently
// be reached at, not just the one the INVITE went to. A phone woken by a VoIP
// push restarts its SIP stack and re-registers from a new source port, which
// retires the invite-time address; a CANCEL aimed only there was silently
// dropped and the phone rang on after the far end hung up (observed
// 2026-09-11: 62862 -> 58591 -> 52543 within seconds).
func (s *Server) sendDialogTeardown(sess *SIPCallSession, reason string) {
	plan, ok := sess.ByePlan()
	if !ok || plan.remote == nil {
		return
	}
	// A phone that is still ringing for a call the far end abandoned needs a
	// CANCEL per invitation, not a BYE: no dialog exists yet.
	if sess.Direction == "inbound" && sess.State() == "init" {
		s.cancelInvitations(sess, plan, reason)
		return
	}
	localIP := s.localIPFor(plan.remote)

	type teardownTarget struct {
		addr   *net.UDPAddr
		origin string
	}
	var targets []teardownTarget
	seen := make(map[string]bool)
	add := func(addr *net.UDPAddr, origin string) {
		if addr == nil || seen[addr.String()] {
			return
		}
		seen[addr.String()] = true
		targets = append(targets, teardownTarget{addr: addr, origin: origin})
	}
	add(plan.remote, "invite")
	if s.registrar != nil {
		for _, reg := range s.registrar.All() {
			if plan.username != "" && reg.Username != plan.username {
				continue
			}
			add(contactAddr(reg.Contact), "reregister")
		}
	}

	for _, tg := range targets {
		// 只有发送地址换成新注册的那个；Request-URI 保持 INVITE 的原值，
		// 因为 RFC 3261 §9.1 要求 CANCEL 的 Request-URI 与 INVITE 完全相同，
		// 客户端靠它加上 Call-ID/CSeq/branch 认出该 CANCEL 属于哪个事务。
		p := plan
		p.remote = tg.addr
		method, message := teardownMessage(sess.Direction, sess.State(), sess.LocalTag(), p, localIP)
		if message == "" {
			continue
		}
		for attempt := 1; attempt <= 2; attempt++ {
			if _, err := s.conn.WriteToUDP([]byte(message), tg.addr); err != nil {
				slog.Warn("sip teardown failed", "call", sess.ID, "method", method, "target", tg.origin, "err", err)
				break
			}
			slog.Info("sip teardown sent", "call", sess.ID, "method", method, "reason", reason, "remote", tg.addr.String(), "target", tg.origin, "attempt", attempt)
			if attempt == 1 {
				time.Sleep(teardownRepeatDelay)
			}
		}
	}
}

// cancelInvitations silences a phone that is still ringing for a cellular call
// the far end has given up on.
//
// Every invitation this gateway sent gets its own CANCEL aimed at the contact
// that received it, because a phone woken by the VoIP push restarts its SIP
// stack and re-registers from a new port: the invitation it is actually
// showing is then on a different address than the first one, and a CANCEL only
// matches the transaction it names. Sending one CANCEL to "the current
// registration" (as this used to) missed it either way.
func (s *Server) cancelInvitations(sess *SIPCallSession, plan byePlan, reason string) {
	attempts := sess.InviteAttempts()
	if len(attempts) == 0 {
		// No invitation was recorded (an older session, or one rebuilt by a
		// test): fall back to the dialog fields.
		attempts = []inviteAttempt{{addr: plan.remote, req: plan.inviteReq}}
	}
	for _, a := range attempts {
		if a.addr == nil {
			continue
		}
		message := cancelMessage(a.req, s.localIPFor(a.addr))
		if message == "" {
			// The raw INVITE is the only reliable source for the Request-URI
			// and the Via branch. Without it, rebuild from the stored fields so
			// the call is still cancelled rather than silently left ringing.
			fallback := plan
			fallback.remote = a.addr
			_, message = teardownMessage("inbound", "init", sess.LocalTag(), fallback, s.localIPFor(a.addr))
		}
		if message == "" {
			continue
		}
		for attempt := 1; attempt <= 2; attempt++ {
			if _, err := s.conn.WriteToUDP([]byte(message), a.addr); err != nil {
				slog.Warn("sip teardown failed", "call", sess.ID, "method", "CANCEL", "remote", a.addr.String(), "err", err)
				break
			}
			slog.Info("sip teardown sent", "call", sess.ID, "method", "CANCEL", "reason", reason, "remote", a.addr.String(), "target", "invite", "attempt", attempt)
			if attempt == 1 {
				time.Sleep(teardownRepeatDelay)
			}
		}
	}
}

// cancelMessage builds the CANCEL for an INVITE this gateway sent, copying
// every header the CANCEL must repeat out of that very message.
//
// RFC 3261 §9.1 requires a CANCEL's Request-URI, Call-ID, From, To and CSeq
// number to be identical to those of the INVITE, and its top Via to be the
// INVITE's. Rebuilding them from separate bookkeeping is exactly how this
// broke: the CANCEL's Request-URI was computed from the client's Contact while
// the INVITE had been addressed to sip:<user>@<gateway>, so the two disagreed —
// and a phone unable to match the CANCEL to the invitation it was showing kept
// ringing after the caller had hung up (observed 2026-09-11). Deriving the
// CANCEL from the sent bytes makes that drift impossible.
func cancelMessage(inviteReq, localIP string) string {
	if inviteReq == "" || localIP == "" {
		return ""
	}
	reqURI := requestURIOf(inviteReq)
	branch := viaBranchOf(inviteReq)
	from := parseHeader(inviteReq, "From")
	to := parseHeader(inviteReq, "To")
	callID := parseHeader(inviteReq, "Call-ID")
	cseq := parseHeader(inviteReq, "CSeq")
	if reqURI == "" || branch == "" || from == "" || to == "" || callID == "" || cseq == "" {
		return ""
	}
	return fmt.Sprintf("CANCEL %s SIP/2.0\r\nVia: SIP/2.0/UDP %s:5060;branch=%s;rport\r\nMax-Forwards: 70\r\nFrom: %s\r\nTo: %s\r\nCall-ID: %s\r\nCSeq: %d CANCEL\r\nContent-Length: 0\r\n\r\n",
		reqURI, localIP, branch, from, to, callID, cseqNumber(cseq))
}

// requestURIOf returns the Request-URI of a SIP request message.
func requestURIOf(msg string) string {
	line, _, _ := strings.Cut(msg, "\r\n")
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return ""
	}
	return fields[1]
}

// viaBranchOf returns the branch parameter of the topmost Via header — the
// value that ties a CANCEL to the INVITE transaction it cancels.
func viaBranchOf(msg string) string {
	via := parseHeader(msg, "Via")
	i := strings.Index(via, "branch=")
	if i < 0 {
		return ""
	}
	rest := via[i+len("branch="):]
	if j := strings.IndexAny(rest, ";, \t"); j >= 0 {
		rest = rest[:j]
	}
	return strings.TrimSpace(rest)
}

// teardownMessage builds the SIP message that ends a call at the client, or
// "" when this dialog is past notifying. It depends on no Server state so the
// exact bytes can be asserted offline.
//
// Which message is correct depends on how far the call got:
//
//   - client still being rung (inbound INVITE unanswered) -> CANCEL, the only
//     way to silence a phone ringing for a call the far end has abandoned;
//   - connected -> BYE, which closes the dialog and clears the call screen;
//   - dialled out but never answered -> a final 480, so the client gives up
//     instead of ringing until its own transaction timer expires.
func teardownMessage(direction, state, localTag string, plan byePlan, localIP string) (string, string) {
	if plan.remote == nil || plan.callID == "" {
		return "", ""
	}
	switch {
	case direction == "inbound" && state == "init":
		// No dialog exists yet. The CANCEL has to look like the INVITE the
		// phone is showing, so derive it from that very message whenever we
		// still have it.
		if msg := cancelMessage(plan.inviteReq, localIP); msg != "" {
			return "CANCEL", msg
		}
		// Fallback for a plan captured without the raw INVITE (tests, and any
		// caller that only kept the header fields): rebuild from those.
		msg := fmt.Sprintf("CANCEL %s SIP/2.0\r\nVia: SIP/2.0/UDP %s:5060;branch=%s;rport\r\nMax-Forwards: 70\r\nFrom: %s\r\nTo: %s\r\nCall-ID: %s\r\nCSeq: %d CANCEL\r\nContent-Length: 0\r\n\r\n",
			plan.reqURI, localIP, plan.inviteBranch, plan.from, plan.to, plan.callID, plan.inviteCSeq)
		return "CANCEL", msg
	case state == "init" || state == "dialing":
		if plan.inviteReq == "" {
			return "", ""
		}
		return "480", buildResponse(plan.inviteReq, 480, "Temporarily Unavailable", "", "", ";tag="+localTag)
	default:
		// BYE opens a new transaction, so it needs its own branch, and a
		// CSeq number higher than anything the client has sent.
		msg := fmt.Sprintf("BYE %s SIP/2.0\r\nVia: SIP/2.0/UDP %s:5060;branch=z9hG4bK%s;rport\r\nMax-Forwards: 70\r\nFrom: %s\r\nTo: %s\r\nCall-ID: %s\r\nCSeq: %d BYE\r\nContent-Length: 0\r\n\r\n",
			plan.reqURI, localIP, uuid.NewString()[:12], plan.from, plan.to, plan.callID, plan.inviteCSeq+1)
		return "BYE", msg
	}
}

// contactURI turns a Contact header value into a Request-URI for a request we
// originate (BYE/CANCEL). Falls back to the packet's source address when the
// client sent no usable Contact, so the teardown is never silently dropped.
func contactURI(contact string, remote *net.UDPAddr, user string) string {
	if i := strings.Index(contact, "sip:"); i >= 0 {
		rest := contact[i:]
		if j := strings.IndexAny(rest, ">;"); j >= 0 {
			rest = rest[:j]
		}
		if rest = strings.TrimSpace(rest); rest != "" {
			return rest
		}
	}
	if remote == nil {
		return ""
	}
	return fmt.Sprintf("sip:%s@%s", user, remote.String())
}

// inboundCallerHeaders renders the caller identity for the INVITE that rings
// a SIP client for a cellular call.
//
// iOS builds the lock-screen caller from the From display name (and from
// P-Asserted-Identity when it is trusted); a bare "From: <sip:number@host>"
// left Linphone showing no number at all for an otherwise perfectly delivered
// incoming call (2026-09-11). The number therefore goes out in every place a
// client may look: the display name, P-Asserted-Identity and Remote-Party-ID.
// A call with no caller id gets a neutral "unknown" URI rather than an empty
// header, which some clients reject outright.
func inboundCallerHeaders(peer, localIP string) (extra, from string) {
	if peer == "" {
		return "", fmt.Sprintf("<sip:unknown@%s>", localIP)
	}
	name := `"` + peer + `"`
	uri := fmt.Sprintf("<sip:%s@%s>", peer, localIP)
	extra = "P-Asserted-Identity: " + name + " " + uri + "\r\n" +
		"Remote-Party-ID: " + name + " " + uri + ";party=calling;screen=yes\r\n"
	return extra, name + " " + uri
}

// cseqNumber reads the sequence number out of a "CSeq: <n> <METHOD>" header.
func cseqNumber(cseq string) int {
	fields := strings.Fields(cseq)
	if len(fields) == 0 {
		return 0
	}
	n, err := strconv.Atoi(fields[0])
	if err != nil {
		return 0
	}
	return n
}

func extractSIPUser(hdr string) string {
	s := hdr
	if i := strings.Index(s, "sip:"); i >= 0 {
		s = s[i+4:]
	} else {
		return ""
	}
	if j := strings.Index(s, "@"); j >= 0 {
		return s[:j]
	}
	if j := strings.Index(s, ">"); j >= 0 {
		return s[:j]
	}
	return strings.Fields(s)[0]
}
func extractSDP(msg string) string {
	parts := strings.Split(msg, "\r\n\r\n")
	if len(parts) < 2 {
		return ""
	}
	return parts[1]
}

// sdpOfferSummary 提取 SDP 中与"客户端为什么秒挂"相关的行：m= 媒体行
// （协议是 RTP/AVP 还是 SAVP/SAVPF）、rtpmap、加密与 ICE 属性。用于呼出
// 接通瞬间被客户端 ACK+BYE 的诊断（2026-09-11）。
func sdpOfferSummary(msg string) string {
	sdp := extractSDP(msg)
	if sdp == "" {
		return ""
	}
	var keep []string
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "m=") || strings.HasPrefix(line, "a=rtpmap") ||
			strings.HasPrefix(line, "a=crypto") || strings.Contains(line, "SAVP") ||
			strings.HasPrefix(line, "a=setup") || strings.HasPrefix(line, "a=fingerprint") {
			keep = append(keep, line)
		}
	}
	return strings.Join(keep, " | ")
}
func parseSDPRTP(sdp string) (string, int) {
	var ip string
	var port int
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "c=IN IP4 ") {
			ip = strings.TrimSpace(line[len("c=IN IP4 "):])
		}
		if strings.HasPrefix(line, "m=audio ") {
			fmt.Sscanf(line, "m=audio %d", &port)
		}
	}
	return ip, port
}

// answerTimeout bounds how long we wait for the cellular leg to be
// answered before giving up on the SIP call.
const answerTimeout = 90 * time.Second

// localTailnetIP returns the NAS tailnet IPv4 address by walking its
// interfaces, preferring tailscale0.
func localTailnetIP() string {
	if addrs, err := net.InterfaceAddrs(); err == nil {
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && ipnet.IP.To4() != nil {
				if strings.HasPrefix(ipnet.IP.String(), "100.") {
					return ipnet.IP.String()
				}
			}
		}
	}
	return ""
}

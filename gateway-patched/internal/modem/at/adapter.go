package at

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/cellbridge/cellbridge/gateway/internal/id"
	"github.com/cellbridge/cellbridge/gateway/internal/modem"
	"github.com/cellbridge/cellbridge/gateway/internal/modem/qdc507"
	"github.com/cellbridge/cellbridge/gateway/internal/sms"
	"github.com/google/uuid"
)

// Adapter is the conservative V1 AT command adapter. It deliberately keeps
// vendor-specific audio commands out of the control path; voice audio is
// provided by the selected VoiceAudio backend while this type owns calls,
// SMS, and line state.
type Adapter struct {
	client *Client
	mu     sync.Mutex
	active modem.CallID
	// pendingPeer holds the caller number parsed from +CLIP. It usually
	// arrives a few milliseconds AFTER the first RING, so the incoming
	// event is published slightly late (see emitIncomingDelayed) to carry
	// the caller id instead of "unknown".
	pendingPeer  string
	incomingSent bool
	clipOnce     sync.Once
	capMu        sync.RWMutex
	caps         modem.Capabilities
	events       chan modem.ModemEvent
	close        sync.Once
}

func NewAdapter(client *Client) *Adapter {
	adapter := &Adapter{client: client, events: make(chan modem.ModemEvent, 32)}
	if client != nil {
		client.SetLineHandler(adapter.HandleURC)
	}
	return adapter
}

func (a *Adapter) Probe(ctx context.Context) (modem.Capabilities, error) {
	if a.client == nil {
		return modem.Capabilities{}, fmt.Errorf("AT client is unavailable")
	}
	manufacturer, err := firstPayload(a.client.Exchange(ctx, "AT+CGMI"))
	if err != nil {
		return modem.Capabilities{}, err
	}
	// Enable caller-id presentation so inbound calls carry a number
	// instead of surfacing as "unknown". Idempotent, and harmless on
	// modems where it is already on.
	a.clipOnce.Do(func() {
		_, _ = a.client.Exchange(ctx, "AT+CLIP=1")
	})
	model, _ := firstPayload(a.client.Exchange(ctx, "AT+CGMM"))
	revision, _ := firstPayload(a.client.Exchange(ctx, "AT+CGMR"))
	capabilities := modem.Capabilities{
		Vendor:              manufacturer,
		Model:               model,
		Tier:                modem.CapabilitySMSOnly,
		SMS:                 true,
		FirmwareFingerprint: strings.TrimSpace(manufacturer + " " + model + " " + revision),
	}
	if voiceCapabilities, capabilityErr := qdc507.ProbeCapabilities(ctx, a.client, manufacturer, model); capabilityErr == nil {
		capabilities.Voice = voiceCapabilities.Voice
		capabilities.DTMF = voiceCapabilities.DTMF
		capabilities.Audio = voiceCapabilities.Audio
		capabilities.RequiresBootstrap = voiceCapabilities.RequiresBootstrap
		capabilities.Tier = voiceCapabilities.Tier
	}
	a.capMu.Lock()
	a.caps = capabilities
	a.capMu.Unlock()
	return capabilities, nil
}

func (a *Adapter) Status(ctx context.Context) (modem.LineStatus, error) {
	if a.client == nil {
		return modem.LineStatus{}, fmt.Errorf("AT client is unavailable")
	}
	simLines, err := a.client.Exchange(ctx, "AT+CPIN?")
	if err != nil {
		return modem.LineStatus{}, err
	}
	registrationLines, err := a.client.Exchange(ctx, "AT+CEREG?")
	if err != nil {
		return modem.LineStatus{}, err
	}
	signalLines, err := a.client.Exchange(ctx, "AT+CSQ")
	if err != nil {
		return modem.LineStatus{}, err
	}
	a.capMu.RLock()
	capabilities := a.caps
	a.capMu.RUnlock()
	if capabilities.Tier == "" {
		capabilities.Tier = modem.CapabilitySMSOnly
	}
	voiceState := "unavailable"
	if capabilities.Voice {
		voiceState = "control_only"
	}
	status := modem.LineStatus{
		SIM:            normalizeSIM(payload(simLines)),
		Registration:   normalizeRegistration(payload(registrationLines)),
		Signal:         modem.Signal{RSSI: parseRSSI(payload(signalLines))},
		CapabilityTier: capabilities.Tier,
		Voice:          voiceState,
		SMS:            "ready",
	}
	status.Signal.Bars = signalBars(status.Signal.RSSI)
	a.mu.Lock()
	if a.active != "" {
		active := a.active
		status.ActiveCallID = &active
	}
	a.mu.Unlock()
	return status, nil
}

// WaitReady polls the AT channel until the modem answers "AT" with
// OK (or the context ends). After a NAS reboot the module's internal
// system re-boots on its own schedule; waiting here turns a dial's
// failure mode from "immediate 500" into "ring while the module
// comes up".
func (a *Adapter) WaitReady(ctx context.Context) error {
	if a.client == nil {
		return fmt.Errorf("AT client is unavailable")
	}
	// Each probe gets a short independent timeout so a hung port does
	// not consume the whole ready budget.
	deadline := 120 * time.Second
	waitCtx, cancel := context.WithTimeout(ctx, deadline)
	defer cancel()
	attempt := 0
	for {
		if err := waitCtx.Err(); err != nil {
			return fmt.Errorf("QDC507 AT channel not ready after %s: %w", deadline, err)
		}
		probeCtx, probeCancel := context.WithTimeout(waitCtx, 2*time.Second)
		_, err := a.client.Exchange(probeCtx, "AT")
		probeCancel()
		if err == nil {
			slog.Info("modem AT channel ready", "after_attempts", attempt+1)
			return nil
		}
		attempt++
		select {
		case <-waitCtx.Done():
			return waitCtx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

func (a *Adapter) Dial(ctx context.Context, peer string) (modem.CallID, error) {
	a.mu.Lock()
	busy := a.active != ""
	a.mu.Unlock()
	if busy {
		return "", modem.ErrActiveCall
	}
	// After a NAS reboot the module's internal system boots on its own
	// schedule (USB re-enumeration + Android userspace, which can take
	// minutes). Sending ATD into a not-yet-ready modem just burns the
	// dial deadline and produces a 500 to the SIP client. The dial path
	// calls WaitReady upfront (see SIPCallSession.Dial), so by the time
	// we reach here the AT channel is known to answer; keep ATD's own
	// deadline tight so a mid-dial hang still fails fast.
	if _, err := a.client.Exchange(ctx, "ATD"+strings.TrimSpace(peer)+";"); err != nil {
		return "", err
	}
	callID, err := id.New("call_", 16)
	if err != nil {
		return "", err
	}
	a.mu.Lock()
	a.active = modem.CallID(callID)
	a.mu.Unlock()
	return modem.CallID(callID), nil
}

func (a *Adapter) Answer(ctx context.Context, callID modem.CallID) error {
	if err := a.validateActive(callID); err != nil {
		return err
	}
	_, err := a.client.Exchange(ctx, "ATA")
	return err
}

func (a *Adapter) Hangup(ctx context.Context, callID modem.CallID) error {
	if err := a.validateActive(callID); err != nil {
		return err
	}
	_, err := a.client.Exchange(ctx, "ATH")
	if err == nil {
		a.finishActive(callID, "local_hangup")
	}
	return err
}

func (a *Adapter) SendDTMF(ctx context.Context, callID modem.CallID, digit rune) error {
	if err := a.validateActive(callID); err != nil {
		return err
	}
	if !strings.ContainsRune("0123456789*#ABCD", digit) {
		return fmt.Errorf("invalid DTMF digit %q", digit)
	}
	_, err := a.client.Exchange(ctx, fmt.Sprintf("AT+VTS=\"%c\"", digit))
	return err
}

func (a *Adapter) SendSMS(ctx context.Context, destination string, payload modem.SMSPayload) (modem.SMSID, error) {
	destination = strings.TrimSpace(destination)
	// 短号 + 纯 GSM7 正文走文本模式：模块原生支持，少一次 PDU 编解码。
	// 含中文等非 GSM7 字符时必须落到 PDU 分支——文本模式配 AT+CSCS="GSM"
	// 会把汉字映射成问号，而改用 UCS2 字符集又要求号码和正文都手工编码成
	// UTF-16BE 十六进制。PDU 路径的编码器已正确处理 GSM7/UCS2 与分片。
	if len(destination) <= 6 && payload.Body != "" && sms.CanEncodeGSM7(payload.Body) {
		if _, err := a.client.SendTextSMS(ctx, destination, payload.Body); err != nil {
			if errors.Is(err, ErrSubmissionResultUnknown) {
				return "", fmt.Errorf("%w: %v", modem.ErrSMSSubmissionUnknown, err)
			}
			return "", err
		}
		messageID, err := id.New("sms_", 16)
		return modem.SMSID(messageID), err
	}
	if payload.PDU == "" {
		return "", fmt.Errorf("SMS PDU is required")
	}
	pduBytes := len(strings.TrimSpace(payload.PDU)) / 2
	if pduBytes < 2 {
		return "", fmt.Errorf("invalid SMS PDU length")
	}
	// AT+CMGS takes TPDU octets, excluding the SMSC length octet.
	smscLength := 0
	if value, err := strconv.ParseInt(payload.PDU[:2], 16, 8); err == nil {
		smscLength = int(value)
	}
	tpduLength := pduBytes - 1 - smscLength
	if tpduLength < 1 {
		return "", fmt.Errorf("invalid SMS TPDU length")
	}
	if _, err := a.client.SendPDU(ctx, tpduLength, payload.PDU); err != nil {
		if errors.Is(err, ErrSubmissionResultUnknown) {
			return "", fmt.Errorf("%w: %v", modem.ErrSMSSubmissionUnknown, err)
		}
		return "", err
	}
	messageID, err := id.New("sms_", 16)
	return modem.SMSID(messageID), err
}

func (a *Adapter) ListSMS(ctx context.Context, cursor modem.SMSCursor) ([]modem.RawSMS, modem.SMSCursor, error) {
	// Explicitly select the modem's message storage ("MT" = module phone
	// memory). Without this, CMGL lists the *current preferred* storage
	// (often SM/SR on QDC507), which is empty because inbound SMS lands
	// in MT — so messages are never ingested, pushed, or deleted.
	// Observed 2026-09-06: +CPMS showed "MT",2,23 but CMGL=4 returned
	// nothing; user stopped receiving SMS entirely.
	if _, err := a.client.Exchange(ctx, "AT+CPMS=\"MT\""); err != nil {
		return nil, cursor, err
	}
	if _, err := a.client.Exchange(ctx, "AT+CMGF=0"); err != nil {
		return nil, cursor, err
	}
	lines, err := a.client.Exchange(ctx, "AT+CMGL=4")
	if err != nil {
		return nil, cursor, err
	}
	var result []modem.RawSMS
	var current *modem.RawSMS
	lastIndex := strings.TrimSpace(string(cursor))
	for _, line := range lines {
		if strings.HasPrefix(line, "+CMGL:") {
			fields := strings.Split(strings.TrimSpace(strings.TrimPrefix(line, "+CMGL:")), ",")
			if len(fields) == 0 {
				continue
			}
			index, parseErr := strconv.Atoi(strings.TrimSpace(fields[0]))
			if parseErr != nil {
				continue
			}
			// 与上面的 AT+CPMS="MT" 保持一致：这里列出的确实是 MT 存储。
			// 原先把存储名写死为 "SM"，入库后会误导排查。
			current = &modem.RawSMS{ModemStorage: "MT", ModemIndex: index}
			lastIndex = strconv.Itoa(index)
			continue
		}
		if current != nil && !IsFinal(line) && !strings.HasPrefix(line, "+") {
			pdu, decodeErr := hex.DecodeString(strings.TrimSpace(line))
			if decodeErr == nil {
				current.RawPDU = pdu
				result = append(result, *current)
			}
			current = nil
		}
	}
	return result, modem.SMSCursor(lastIndex), nil
}

func (a *Adapter) DeleteSMS(ctx context.Context, storageIndex string) error {
	// CMGD without an explicit storage deletes from the *current
	// preferred* storage; pin it to MT (same reason as ListSMS) so
	// engine.go's post-ingest cleanup actually removes the message.
	if _, err := a.client.Exchange(ctx, "AT+CPMS=\"MT\""); err != nil {
		return err
	}
	if _, err := a.client.Exchange(ctx, "AT+CMGD="+strings.TrimSpace(storageIndex)); err != nil {
		return err
	}
	return nil
}

func (a *Adapter) Events() <-chan modem.ModemEvent { return a.events }

// clccActive reports whether the +CLCC lines describe a call in the given
// direction that has reached state 0 (active). dir < 0 matches either
// direction. Kept separate from the polling loop so the direction matching
// is unit-testable without a live modem.
func clccActive(lines []string, dir int) bool {
	for _, line := range lines {
		if !strings.HasPrefix(line, "+CLCC:") {
			continue
		}
		// +CLCC: <id>,<dir>,<state>,<mode>,<mpty>,<number>,<type>
		fields := strings.Split(strings.TrimPrefix(line, "+CLCC:"), ",")
		if len(fields) < 3 {
			continue
		}
		callDir, dirErr := strconv.Atoi(strings.TrimSpace(fields[1]))
		state, stateErr := strconv.Atoi(strings.TrimSpace(fields[2]))
		if dirErr != nil || stateErr != nil {
			continue
		}
		if state == 0 && (dir < 0 || callDir == dir) {
			return true
		}
	}
	return false
}

// WaitActive polls AT+CLCC until an outgoing call is answered. Kept for the
// dial path; inbound uses WaitActiveDir with dir=1.
func (a *Adapter) WaitActive(ctx context.Context) (bool, error) {
	return a.WaitActiveDir(ctx, modem.CLCCDirOutgoing)
}

// WaitActiveDir polls AT+CLCC until a call in the given direction reaches
// state 0 (active), or the context ends. Opening UAC capture before the
// cellular leg is active wedges the ALSA ASYNC stream into an XRUN that
// reads silence forever, so the SIP bridge must wait for this before
// starting audio.
//
// Upstream hard-coded dir=0 here. An inbound (mobile terminated) call is
// reported with dir=1, so the answer path could never confirm the pickup:
// it blocked for its entire deadline and only then started the audio
// bridge — by which time the caller had already hung up. Every answered
// inbound call was silent while outbound worked, because outbound really is
// dir=0.
func (a *Adapter) WaitActiveDir(ctx context.Context, dir int) (bool, error) {
	var lastSeen []string
	for {
		select {
		case <-ctx.Done():
			slog.Warn("clcc wait timed out", "dir", dir, "last_clcc", lastSeen)
			return false, ctx.Err()
		default:
		}
		lines, err := a.client.Exchange(ctx, "AT+CLCC")
		if err == nil {
			if clccActive(lines, dir) {
				slog.Info("clcc call active", "dir", dir, "lines", lines)
				return true, nil
			}
			lastSeen = lines
		}
		timer := time.NewTimer(300 * time.Millisecond)
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			slog.Warn("clcc wait timed out", "dir", dir, "last_clcc", lastSeen)
			return false, ctx.Err()
		}
	}
}

func (a *Adapter) Run(ctx context.Context) error {
	if a.client == nil {
		return fmt.Errorf("AT client is unavailable")
	}
	return a.client.Run(ctx)
}

// HandleURC is called by a serial reader when a line arrives outside an AT
// command exchange. It is public so a platform-specific reader can preserve
// unsolicited RING/NO CARRIER events without coupling it to the parser.
func (a *Adapter) HandleURC(line string) {
	// A URC may arrive exactly as Close() shuts the events channel
	// down (observed as a restart-time panic: "send on closed
	// channel"). Swallow it instead of crashing the gateway.
	defer func() {
		if recovered := recover(); recovered != nil {
			slog.Warn("adapter URC dropped during shutdown", "cause", recovered)
		}
	}()
	line = strings.TrimSpace(line)
	a.mu.Lock()
	callID := a.active
	a.mu.Unlock()
	var event modem.ModemEvent
	switch {
	case strings.HasPrefix(line, "+CLIP:"):
		// +CLIP: "13800138000",129,,,,0 — caller id, normally the line
		// immediately after the first RING. Stash it for
		// emitIncomingDelayed, which publishes the incoming event a
		// fraction later so it can carry the number.
		a.mu.Lock()
		a.pendingPeer = clipNumber(line)
		a.mu.Unlock()
		return
	case line == "RING":
		if callID == "" {
			callID = modem.CallID(uuid.NewString())
			a.mu.Lock()
			a.active = callID
			a.mu.Unlock()
		}
		// A cellular call rings every few seconds. Only the first RING
		// opens the incoming event (and with it one INVITE per client);
		// every later RING is the same call and must not re-ring the
		// SIP client or spawn a second session.
		a.mu.Lock()
		already := a.incomingSent
		a.incomingSent = true
		a.mu.Unlock()
		if already {
			return
		}
		go a.emitIncomingDelayed(callID)
		return
	case strings.Contains(line, "NO CARRIER"), strings.Contains(line, "BUSY"), strings.Contains(line, "NO ANSWER"):
		event = modem.ModemEvent{Kind: "ended", CallID: callID, Raw: line}
		// The modem terminated the call (e.g. an unanswered inbound call).
		// Clear the active marker here, or every later dial fails with
		// ErrActiveCall until the process restarts.
		a.mu.Lock()
		if a.active == callID && callID != "" {
			a.active = ""
		}
		a.incomingSent = false
		a.pendingPeer = ""
		a.mu.Unlock()
	default:
		return
	}
	select {
	case a.events <- event:
	default:
	}
}

// incomingClipWait bounds how long the first RING waits for its +CLIP
// companion line before the call is published. The number normally trails
// the RING by a few milliseconds; a fixed sleep either wasted that time on
// every call or, when a status poll happened to own the AT port, expired
// before the number was dispatched and the call surfaced as "unknown".
const incomingClipWait = 800 * time.Millisecond

// emitIncomingDelayed waits for the +CLIP line that follows the first RING,
// then publishes the incoming event carrying the caller number. Without the
// wait every inbound call surfaced as "unknown".
func (a *Adapter) emitIncomingDelayed(callID modem.CallID) {
	deadline := time.Now().Add(incomingClipWait)
	for time.Now().Before(deadline) {
		a.mu.Lock()
		known := a.pendingPeer != ""
		a.mu.Unlock()
		if known {
			break
		}
		time.Sleep(40 * time.Millisecond)
	}
	a.mu.Lock()
	peer := a.pendingPeer
	a.pendingPeer = ""
	a.mu.Unlock()
	select {
	case a.events <- modem.ModemEvent{Kind: "incoming", CallID: callID, Peer: peer}:
	default:
	}
}

// clipNumber extracts the caller number from a +CLIP URC line, e.g.
// +CLIP: "13800138000",129,,,,0 -> 13800138000.
func clipNumber(line string) string {
	rest := strings.TrimSpace(strings.TrimPrefix(line, "+CLIP:"))
	if i := strings.Index(rest, "\""); i >= 0 {
		if j := strings.Index(rest[i+1:], "\""); j >= 0 {
			return rest[i+1 : i+1+j]
		}
	}
	return ""
}

func (a *Adapter) Close() error {
	var err error
	a.close.Do(func() {
		close(a.events)
		if a.client != nil {
			err = a.client.Close()
		}
	})
	return err
}

func (a *Adapter) validateActive(callID modem.CallID) error {
	a.mu.Lock()
	active := a.active
	a.mu.Unlock()
	if active == "" || (callID != "" && active != callID) {
		return fmt.Errorf("active call mismatch")
	}
	return nil
}

func (a *Adapter) finishActive(callID modem.CallID, reason string) {
	a.mu.Lock()
	if a.active == callID {
		a.active = ""
	}
	// Reset the inbound-call bookkeeping too. These flags are what stop a
	// re-RING of the *same* call from opening a second session, but leaving
	// them set after a LOCAL hangup (client declines, ring timeout) made the
	// next genuinely new inbound call look like a repeat RING and get
	// dropped silently — inbound calling then stayed dead until the module
	// happened to send NO CARRIER or the gateway was restarted.
	a.incomingSent = false
	a.pendingPeer = ""
	a.mu.Unlock()
	select {
	case a.events <- modem.ModemEvent{Kind: "ended", CallID: callID, Raw: reason}:
	default:
	}
}

func firstPayload(lines []string, err error) (string, error) {
	if err != nil {
		return "", err
	}
	return payload(lines), nil
}

func payload(lines []string) string {
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" && line != "OK" && !IsFinal(line) && !strings.HasPrefix(line, "AT") {
			return line
		}
	}
	return ""
}

func normalizeSIM(value string) string {
	value = strings.ToLower(value)
	switch {
	case strings.Contains(value, "ready"):
		return "ready"
	case strings.Contains(value, "pin"), strings.Contains(value, "puk"):
		return "locked"
	case strings.Contains(value, "not ready"):
		return "absent"
	default:
		return "unknown"
	}
}

func normalizeRegistration(value string) string {
	value = strings.TrimSpace(value)
	if index := strings.LastIndex(value, ","); index >= 0 {
		value = strings.TrimSpace(value[index+1:])
	}
	switch value {
	case "1", "5":
		return "registered"
	case "2":
		return "searching"
	case "3":
		return "denied"
	default:
		return "unknown"
	}
}

func parseRSSI(value string) int {
	value = strings.TrimSpace(value)
	if index := strings.Index(value, ":"); index >= 0 {
		value = strings.TrimSpace(value[index+1:])
	}
	if index := strings.Index(value, ","); index >= 0 {
		value = value[:index]
	}
	rssi, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || rssi == 99 {
		return 0
	}
	return -113 + rssi*2
}

func signalBars(rssi int) int {
	switch {
	case rssi >= -75:
		return 4
	case rssi >= -90:
		return 3
	case rssi >= -105:
		return 2
	case rssi > -113:
		return 1
	default:
		return 0
	}
}

var _ modem.ModemControl = (*Adapter)(nil)

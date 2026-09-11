package sip

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"sync"
	"time"

	"github.com/cellbridge/cellbridge/gateway/internal/modem"
	"github.com/cellbridge/cellbridge/gateway/internal/voice"
)

type SIPCallSession struct {
	ID        string
	Peer      string
	Direction string // outbound/inbound
	modem     *modem.ActiveCallAdapter
	audio     modem.VoiceAudio
	media     *MediaSession
	bridge    *voice.Bridge
	ctx       context.Context
	cancel    context.CancelFunc
	mu        sync.Mutex
	state     string
	// localTag is the To-tag this gateway puts on the responses to an
	// outbound INVITE. A dialog's tag must be identical in the provisional
	// and the final response, and the BYE that later ends the call has to
	// carry exactly this tag or the client rejects it as a foreign dialog.
	localTag string
	// modemID is the modem-internal id of the cellular leg, recorded when
	// that leg is set up. Modem "ended" events name that id, so matching on
	// it is what lets a far-end hangup find the right SIP dialog: an
	// outbound session is keyed by the client's Call-ID, which the modem has
	// never heard of.
	modemID modem.CallID
	bye     byePlan
	hasBye  bool
	// invites records every INVITE this gateway has sent to a client contact
	// for a call that is still ringing, verbatim. A phone woken by a VoIP push
	// restarts its SIP stack and re-registers from a NEW source port, so the
	// invitation it is actually showing may sit on a different address than
	// the first one; and a CANCEL only silences the phone when it repeats the
	// invitation byte for byte (RFC 3261 §9.1). Keeping the sent message is
	// therefore the only way to end such a call reliably.
	invites []inviteAttempt
}

// inviteAttempt is one INVITE this gateway sent to one client contact.
//
// req holds the exact bytes that went out, and the CANCEL is derived from them
// rather than rebuilt from the dialog fields: the previous implementation
// assembled the CANCEL's Request-URI from the client's Contact while the
// INVITE had been addressed to sip:<user>@<gateway>, so the two disagreed and
// the phone rang on after the far end had hung up (observed 2026-09-11).
type inviteAttempt struct {
	addr *net.UDPAddr
	req  string
}

// byePlan is everything needed to end an established dialog from our side —
// and, while a call is still ringing, to cancel the pending INVITE.
//
// It is captured from the SIP messages that created the dialog rather than
// rebuilt later, because every field has to match byte-for-byte what the
// client saw: the tags identify the dialog, the CSeq has to be higher than
// the last request the client sent, and a CANCEL is only accepted when it
// reuses the INVITE's Via branch and CSeq number.
type byePlan struct {
	remote       *net.UDPAddr // where to send the teardown
	reqURI       string       // Request-URI: the client's Contact
	from         string       // our From header, carrying our tag
	to           string       // the peer's From/To header, carrying its tag
	callID       string
	inviteCSeq   int    // CSeq number of the INVITE that opened the dialog
	inviteBranch string // Via branch of that INVITE (CANCEL must reuse it)
	inviteReq    string // the raw INVITE, needed to answer it with an error
	// username is the SIP account the dialog belongs to, so a teardown can
	// also be aimed at whatever address that account has registered since
	// the INVITE went out. A phone woken by a VoIP push restarts its SIP
	// stack and re-registers from a NEW source port, which makes the
	// invite-time address dead: the CANCEL sent only there was dropped and
	// the phone rang on after the far end hung up (observed 2026-09-11).
	username string
}

func NewSIPCallSession(id, peer, dir string, modemCtl *modem.ActiveCallAdapter, audio modem.VoiceAudio, media *MediaSession) *SIPCallSession {
	ctx, cancel := context.WithCancel(context.Background())
	br := voice.NewBridge(audio, media)
	return &SIPCallSession{ID: id, Peer: peer, Direction: dir, modem: modemCtl, audio: audio, media: media, bridge: br, ctx: ctx, cancel: cancel, state: "init"}
}

// Dial issues the cellular dial only. It returns as soon as the modem
// accepts ATD; per the 2026-09-04 document (§20) the SIP 200 OK must wait
// for the modem call to actually answer, which AwaitBridge covers.
func (s *SIPCallSession) Dial() error {
	s.mu.Lock()
	s.state = "dialing"
	s.mu.Unlock()
	slog.Info("sip session dialing", "id", s.ID, "peer", s.Peer, "dir", s.Direction)
	if s.Direction == "outbound" {
		// Order matters after a NAS reboot: the module's internal
		// system boots minutes AFTER the NAS (USB re-enumeration +
		// Android userspace). Querying adb (route rotation below) or
		// issuing ATD before the module answers burns the dial budget
		// and returns a 500 to the SIP client. So: 1) wait for the AT
		// channel, 2) rotate the voice route (adb is up by then), 3) ATD.
		waitCtx, waitCancel := context.WithTimeout(s.ctx, 150*time.Second)
		if err := s.modem.WaitReady(waitCtx); err != nil {
			waitCancel()
			return fmt.Errorf("modem not ready: %w", err)
		}
		waitCancel()
		// Recycle the QDC507 UAC route BEFORE dialing: a route session left
		// over from a previous call keeps hw:0,4 RUNNING with a stale USB
		// stream, and any capture opened against it reads silence. The
		// fresh route must be up before ATD so the voice path is streaming
		// when the cellular call connects.
		if preparer, ok := s.audio.(interface {
			PrepareRoute(context.Context) error
		}); ok && preparer != nil {
			prepCtx, prepCancel := context.WithTimeout(s.ctx, 20*time.Second)
			if err := preparer.PrepareRoute(prepCtx); err != nil {
				prepCancel()
				return fmt.Errorf("voice route recycle failed: %w", err)
			}
			prepCancel()
		}
		// Bounded dial: an AT exchange without a deadline can wedge the
		// serial client forever (observed: a hung ATH held the port lock
		// and every later dial blocked until process restart).
		dialCtx, cancel := context.WithTimeout(s.ctx, 15*time.Second)
		defer cancel()
		if err := s.modem.Dial(dialCtx, s.Peer); err != nil {
			return fmt.Errorf("modem dial failed: %w", err)
		}
		// Remember which cellular leg this dialog owns. The modem names the
		// call by this id when it later reports it ended, and that is the
		// only link back to a SIP session keyed by the client's Call-ID.
		s.SetModemCallID(s.modem.PhysicalCallID())
	}
	return nil
}

// AwaitBridge waits for the cellular leg to be ANSWERED (CLCC active)
// and only then starts the PCM<->RTP bridge. Opening the UAC capture
// before the call is active wedges the ALSA ASYNC stream into an XRUN
// that reads silence for the whole call — observed on the QDC507.
func (s *SIPCallSession) AwaitBridge(ctx context.Context) error {
	answered, err := s.modem.WaitActive(ctx)
	if err != nil && ctx.Err() == nil {
		return fmt.Errorf("wait cellular answer failed: %w", err)
	}
	if !answered {
		return fmt.Errorf("cellular call was not answered")
	}
	slog.Info("sip cellular answered", "id", s.ID, "peer", s.Peer)
	callID := modem.CallID(s.ID)
	// CRITICAL: the bridge must run on the SESSION context, not the
	// caller's answer-wait context. The caller cancels its ctx via
	// defer right after this returns; a readLoop bound to that ctx dies
	// immediately and the whole call is silent (observed 2026-09-06:
	// one frame at pcm_peak=111 then nothing for 15s).
	if err := s.bridge.Start(s.ctx, callID); err != nil {
		return fmt.Errorf("voice bridge failed: %w", err)
	}
	s.mu.Lock()
	s.state = "active"
	s.mu.Unlock()
	return nil
}

// beginAnswer atomically claims the pickup of an inbound call. A SIP
// client retransmits its 200 OK until it receives our ACK, so the answer
// path can run more than once for a single pickup; only the winner is
// allowed to touch the modem.
func (s *SIPCallSession) beginAnswer() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state != "init" {
		return false
	}
	s.state = "answering"
	return true
}

// inboundActiveWait bounds how long the answer path waits for the cellular
// leg to report active. The transition completes well under a second once
// ATA is accepted, so a long deadline only delays audio when CLCC misbehaves.
const inboundActiveWait = 8 * time.Second

// AnswerInbound completes an inbound cellular call: it picks up the
// cellular leg (ATA) and then starts the PCM<->RTP bridge, mirroring the
// outbound AwaitBridge path. The caller is already waiting, so a missing
// CLCC confirmation is only logged, never fatal.
func (s *SIPCallSession) AnswerInbound(ctx context.Context) error {
	if err := s.modem.Answer(ctx); err != nil {
		return fmt.Errorf("modem answer failed: %w", err)
	}
	s.SetModemCallID(s.modem.PhysicalCallID())
	waitCtx, waitCancel := context.WithTimeout(s.ctx, inboundActiveWait)
	defer waitCancel()
	// An answered inbound call is reported with +CLCC dir=1. The shared
	// helper matched dir=0 only, so this never confirmed: the answer path
	// burned its whole deadline and every answered inbound call was silent
	// (outbound worked because a dialled call really is dir=0). Accept
	// either direction — V1 permits exactly one concurrent call — and let
	// the clcc log line record what the module actually reported.
	if answered, err := s.modem.WaitActiveDir(waitCtx, modem.CLCCDirAny); err != nil || !answered {
		slog.Warn("inbound cellular not confirmed active", "id", s.ID, "err", err)
	}
	callID := modem.CallID(s.ID)
	if err := s.bridge.Start(s.ctx, callID); err != nil {
		return fmt.Errorf("voice bridge failed: %w", err)
	}
	s.mu.Lock()
	s.state = "active"
	s.mu.Unlock()
	return nil
}

// Hangup tears down the bridge, closes media, and releases the modem
// line so the next call never sees "active modem call exists".
func (s *SIPCallSession) Hangup() error {
	s.cancel()
	_ = s.bridge.Stop(context.Background())
	if s.Direction == "outbound" || s.Direction == "inbound" {
		// Bounded hangup: ATH without a deadline can wedge the serial
		// client's port lock forever, blocking every later dial.
		hangupCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = s.modem.Hangup(hangupCtx)
	}
	if s.media != nil {
		_ = s.media.Close()
	}
	s.mu.Lock()
	s.state = "ended"
	s.mu.Unlock()
	return nil
}

func (s *SIPCallSession) State() string { s.mu.Lock(); defer s.mu.Unlock(); return s.state }

// SetLocalTag records the To-tag used in this gateway's responses, so every
// later response (and the BYE) can reuse it instead of minting a new one.
func (s *SIPCallSession) SetLocalTag(tag string) {
	s.mu.Lock()
	s.localTag = tag
	s.mu.Unlock()
}

func (s *SIPCallSession) LocalTag() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.localTag
}

// ToTag returns the ";tag=..." fragment this dialog's responses must carry,
// or "" when no tag has been pinned yet (the caller then mints one).
func (s *SIPCallSession) ToTag() string {
	tag := s.LocalTag()
	if tag == "" {
		return ""
	}
	return ";tag=" + tag
}

// SetModemCallID records which cellular leg this dialog is talking over.
func (s *SIPCallSession) SetModemCallID(id modem.CallID) {
	s.mu.Lock()
	s.modemID = id
	s.mu.Unlock()
}

func (s *SIPCallSession) ModemCallID() modem.CallID {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.modemID
}

// SetByePlan stores the dialog state captured while the call was set up.
func (s *SIPCallSession) SetByePlan(plan byePlan) {
	s.mu.Lock()
	s.bye = plan
	s.hasBye = true
	s.mu.Unlock()
}

// ByePlan reports the stored dialog state. The second result is false for a
// session that never got far enough to have a dialog to end.
func (s *SIPCallSession) ByePlan() (byePlan, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.bye, s.hasBye
}

// maxInviteAttempts bounds how many contacts one ringing call may invite. A
// client stuck re-registering in a loop must not grow this without bound.
const maxInviteAttempts = 8

// RememberInvite records one invitation and reports whether it is new.
//
// The destination address is the key: inviting the same contact twice rings
// the phone a second time instead of fixing anything, while a contact that has
// moved to a new port is a genuinely new invitation — it is the address the
// phone can still be reached on, and the one its CANCEL will have to match.
func (s *SIPCallSession) RememberInvite(a inviteAttempt) bool {
	if a.addr == nil || a.req == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, have := range s.invites {
		if have.addr != nil && have.addr.String() == a.addr.String() {
			return false
		}
	}
	if len(s.invites) >= maxInviteAttempts {
		return false
	}
	s.invites = append(s.invites, a)
	return true
}

// InviteAttempts returns the invitations sent for this call so the teardown can
// aim a CANCEL at each of them without holding the session lock.
func (s *SIPCallSession) InviteAttempts() []inviteAttempt {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]inviteAttempt, len(s.invites))
	copy(out, s.invites)
	return out
}

package sip

import (
	"sync"
	"sync/atomic"
	"testing"
)

// Regression test for the 2026-09-10 "双向哑 / 音质极差" report.
//
// Upstream handleInvite looked up the Call-ID, then stored the session only
// AFTER Dial() returned. Dial() rotates the QDC507 voice route and issues
// ATD, so the map stayed empty for 2-9s. A retransmitted INVITE (T1=500ms)
// in that window created a second session; both reached voice.Bridge.Start
// and their two readLoops split the same PCM capture stream, delivering
// audio at half rate (50-frame windows taking ~2048ms instead of 1000ms).
//
// claimSession makes "who owns this Call-ID" a single atomic decision.
func TestClaimSessionSingleWinner(t *testing.T) {
	s := &Server{}
	first := &SIPCallSession{ID: "call-1"}
	dup := &SIPCallSession{ID: "call-1"}

	if !s.claimSession("call-1", first) {
		t.Fatal("first claim must win")
	}
	if s.claimSession("call-1", dup) {
		t.Fatal("a retransmission with the same Call-ID must lose, otherwise it starts a second bridge")
	}
	got, ok := s.sessions.Load("call-1")
	if !ok {
		t.Fatal("winning session must be registered")
	}
	if got != first {
		t.Fatal("map must keep the winner, not be overwritten by the duplicate")
	}

	// A finished call releases the Call-ID so a later call can reuse it.
	s.sessions.Delete("call-1")
	if !s.claimSession("call-1", dup) {
		t.Fatal("claim after Delete must win")
	}
}

// The claim must be atomic under concurrency: a SIP client can retransmit
// while the first handler is still inside Dial().
func TestClaimSessionConcurrent(t *testing.T) {
	s := &Server{}
	const n = 64
	var wins int32
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if s.claimSession("race", &SIPCallSession{ID: "race"}) {
				atomic.AddInt32(&wins, 1)
			}
		}()
	}
	wg.Wait()
	if wins != 1 {
		t.Fatalf("exactly one concurrent claim must win, got %d", wins)
	}
}

// Distinct Call-IDs are independent calls and must both be able to claim.
func TestClaimSessionDistinctCallIDs(t *testing.T) {
	s := &Server{}
	if !s.claimSession("a", &SIPCallSession{ID: "a"}) {
		t.Fatal("call a must claim")
	}
	if !s.claimSession("b", &SIPCallSession{ID: "b"}) {
		t.Fatal("call b must claim")
	}
}

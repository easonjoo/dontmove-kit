package sms

import (
	"context"
	"testing"
	"time"

	"github.com/cellbridge/cellbridge/gateway/internal/modem"
)

// expiredContextSMSModem simulates the real failure mode: AT+CMGS burns the
// whole submission deadline and the modem reports failure only once the
// context is already done.
type expiredContextSMSModem struct{}

func (expiredContextSMSModem) SendSMS(ctx context.Context, _ string, _ modem.SMSPayload) (modem.SMSID, error) {
	<-ctx.Done()
	return "", ctx.Err()
}

// TestEnginePersistsFailureWhenSubmissionDeadlineExpires locks in the fix for
// the "stuck at queued" bug: the status write used to reuse the submission
// context, so a timed-out AT+CMGS left the row at "queued" forever and the
// client showed a pending SMS that could never be reconciled.
func TestEnginePersistsFailureWhenSubmissionDeadlineExpires(t *testing.T) {
	database := openTestDB(t)
	engine := NewEngine(database, expiredContextSMSModem{})

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	message, err := engine.Send(ctx, "10010", "测试短信链路")
	if err == nil {
		t.Fatal("expected the submission to fail")
	}
	if message == nil {
		t.Fatal("expected the message row to be reported back")
	}
	if message.Status != "failed" {
		t.Fatalf("returned status = %q, want failed", message.Status)
	}
	var stored string
	if err := database.QueryRowContext(context.Background(), "SELECT status FROM messages WHERE id = ?", message.ID).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored != "failed" {
		t.Fatalf("stored status = %q, want failed (never left at queued)", stored)
	}
}

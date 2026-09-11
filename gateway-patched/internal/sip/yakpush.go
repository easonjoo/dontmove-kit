package sip

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

// yakHTTPClient deliberately ignores HTTP_PROXY/HTTPS_PROXY.
//
// The gateway is frequently started from a shell that exports a proxy URL
// (sandbox / corporate / Clash-style tooling). That proxy answered the push
// request with a bare EOF, so an incoming call produced
//
//	yakpush failed type=voip err="Post https://push.yakteam.com/v1/notify: EOF"
//
// and CallKit never woke even with a valid token. This host reaches the
// internet through a transparent TUN route, where a direct connection is the
// correct behaviour; the env-var proxy only breaks it.
var yakHTTPClient = &http.Client{
	Timeout:   10 * time.Second,
	Transport: &http.Transport{Proxy: nil},
}

// sendYakPush fires the official YakPhone PushKit notification
// (push.yakteam.com/v1/notify) so the phone wakes for an incoming SIP
// call / missed call / SIP message even when YakPhone is suspended.
func (s *Server) sendYakPush(callerURI, pushType, messageBody string) {
	if s.pushToken == "" {
		slog.Warn("yakpush skipped", "reason", "no push token configured", "type", pushType)
		return
	}
	body := map[string]string{
		"token":       s.pushToken,
		"caller_uri":  callerURI,
		"caller_name": strings.TrimPrefix(callerURI, "sip:"),
		"type":        pushType,
	}
	if messageBody != "" {
		body["message_body"] = messageBody
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return
	}
	req, err := http.NewRequest(http.MethodPost, "https://push.yakteam.com/v1/notify", bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := yakHTTPClient.Do(req)
	if err != nil {
		slog.Warn("yakpush failed", "type", pushType, "err", err)
		return
	}
	defer resp.Body.Close()
	// 读回响应体：token 失效/格式错误时端点会回 4xx + 说明。CallKit 没被唤醒时，
	// 这行日志是唯一能区分「token 不对」与「网络不通」的证据。
	detail, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	fields := []any{"type", pushType, "status", resp.Status}
	if len(detail) > 0 {
		fields = append(fields, "body", strings.TrimSpace(string(detail)))
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		slog.Warn("yakpush rejected", fields...)
		return
	}
	slog.Info("yakpush sent", fields...)
}

var _ = context.Background

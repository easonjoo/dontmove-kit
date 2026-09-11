package sip

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Linphone 锁屏来电推送（RFC 8599 + Belledonne FlexiAPI）。
//
// 流程（wiki.linphone.org "Sending push notification to Linphone mobile Apps"）：
//   1. Linphone 注册时在 Contact 里带上 pn-provider/pn-param/pn-prid
//      （旧版是 pn-type=apple;pn-tok=…;app-id=…，两种都解析）；
//   2. 来电时网关 POST https://subscribe.linphone.org/api/push_notification
//      （x-api-key = 免费 sip.linphone.org 账号的 API Key，User 级即可）；
//   3. Belledonne 的 Flexisip Pusher 替我们向 APNs 发 VoIP 推送
//      （只有它持有 org.linphone.phone 的苹果推送证书）；
//   4. Linphone 被唤醒 → 弹 CallKit → 重新 REGISTER；
//   5. 网关的重试循环在此期间持续尝试，新注册一出现 INVITE 即送达。
//
// 注意：请求必须同时携带 x-api-key 与 From（Key 所属账号的 SIP 地址），
// 缺 From 会报 401 Invalid API Key。
// Key 过期的症状：push 返回 401/403 —— 重新在 Mac 上登录
// subscribe.linphone.org 生成一个即可（见 set-linphone-push.sh）。

// linphonePushURLDefault 是 sip.linphone.org 免费账号对应的 FlexiAPI。
// 商业部署（linphone.pro）换 URL 即可。
const linphonePushURLDefault = "https://subscribe.linphone.org/api/push_notification"

// LinphonePushURL 返回生效的推送端点（未配置时给默认值），供 main 记日志用。
func LinphonePushURL(override string) string {
	if override != "" {
		return override
	}
	return linphonePushURLDefault
}

// pushParams 是一次注册里提取的推送信息（RFC 8599）。
type pushParams struct {
	Provider string // "apns"（iOS）/ "fcm"（Android）
	Param    string // pn-param，iOS 形如 <team>.<bundle>.voip
	Prid     string // pn-prid，设备推送 token
}

// valid 报告这组参数是否足以发起一次推送。
func (p pushParams) valid() bool {
	return p.Provider != "" && p.Param != "" && p.Prid != ""
}

// parsePushParams 从 Contact 头里解析 RFC 8599 pn-* 参数；
// 兼容旧式 pn-type=apple;pn-tok=…;app-id=…。
func parsePushParams(contact string) (pushParams, bool) {
	get := func(key string) string {
		for _, part := range strings.Split(contact, ";") {
			part = strings.TrimSpace(part)
			if strings.HasPrefix(part, key+"=") {
				v := strings.TrimPrefix(part, key+"=")
				return strings.Trim(v, `"'`)
			}
		}
		return ""
	}
	pp := pushParams{
		Provider: get("pn-provider"),
		Param:    get("pn-param"),
		Prid:     get("pn-prid"),
	}
	if pp.valid() {
		return pp, true
	}
	// 旧式参数（Flexisip wiki 里的 pn-type/pn-tok/app-id 形式）
	if tok := get("pn-tok"); tok != "" && (get("pn-type") == "apple" || get("pn-type") == "apns") {
		pp = pushParams{Provider: "apns", Param: get("app-id"), Prid: tok}
		if pp.valid() {
			return pp, true
		}
	}
	return pushParams{}, false
}

// sanitizeCallID 使 Call-ID 满足 FlexiAPI 约束（字母数字、~、-）。
// 我们的入呼 Call-ID 形如 "in-<hex/uuid 片段>"，通常本就合规；
// 保险起见仍做一次清洗，并保证与 INVITE 里用的 Call-ID 一致——
// 所以清洗必须发生在 callID 生成之后、推送与 INVITE 之前。
func sanitizeCallID(id string) string {
	var b strings.Builder
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '~':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	return b.String()
}

// cleanPushParam 把 pn-param 规整为 FlexiAPI 可接受的形式。
// FlexiAPI 只允许字母数字、点、下划线；而 Linphone 注册时上报的
// pn-param 可能带 "&remote" 之类的推送方式后缀（RFC 8599 的 remote
// push 变体），必须剥掉，否则整个请求被 422 拒绝。
func cleanPushParam(param string) string {
	if i := strings.Index(param, "&"); i >= 0 {
		param = param[:i]
	}
	return strings.Trim(param, `"'`)
}

// pickCallPrid 从 pn-prid 里选出通话（voip）推送 token。
// Linphone 可能合并上报双 token："<tok>:voip&<tok2>:remote"。
// "call" 推送必须发给持 voip 证书的 token，且 prid 只允许
// 字母数字、-、_、:，"&" 会被 422 拒绝。
func pickCallPrid(prid string) string {
	tokens := strings.Split(prid, "&")
	if len(tokens) == 1 {
		return strings.Trim(prid, `"'`)
	}
	for _, t := range tokens {
		if strings.HasSuffix(t, ":voip") {
			return t
		}
	}
	return tokens[0]
}

var linphoneHTTPClient = &http.Client{
	// 直连（不经系统代理）：yakpush.go 同款理由，代理会 EOF/502。
	Timeout:   10 * time.Second,
	Transport: &http.Transport{Proxy: nil},
}

// sendLinphonePush 对一组注册参数发起一次 "call" 推送。
// 阻塞至 HTTP 返回（≤10s），由调用方决定放不放 goroutine。
func (s *Server) sendLinphonePush(pp pushParams, callID string) {
	key := s.linphonePushKey
	if key == "" || !pp.valid() {
		return
	}
	url := s.linphonePushURL
	if url == "" {
		url = linphonePushURLDefault
	}
	payload, err := json.Marshal(map[string]string{
		"pn_provider": pp.Provider,
		"pn_param":    cleanPushParam(pp.Param),
		"pn_prid":     pickCallPrid(pp.Prid),
		"type":        "call",
		"call_id":     sanitizeCallID(callID),
	})
	if err != nil {
		return
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("x-api-key", key)
	// FlexiAPI 要求 From = Key 所属账号的 SIP 地址；缺失时报 401 Invalid API Key。
	if s.linphonePushFrom != "" {
		req.Header.Set("From", s.linphonePushFrom)
	}
	resp, err := linphoneHTTPClient.Do(req)
	if err != nil {
		slog.Warn("linphonepush failed", "err", err)
		return
	}
	defer resp.Body.Close()
	detail, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	fields := []any{"status", resp.Status}
	if len(detail) > 0 {
		fields = append(fields, "body", strings.TrimSpace(string(detail)))
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		slog.Warn("linphonepush rejected", fields...)
		if resp.StatusCode == 401 || resp.StatusCode == 403 {
			slog.Warn("linphonepush hint: API Key 无效/过期/IP 变化 —— 在 Mac 上重新登录 subscribe.linphone.org 生成并更新 ~/.cellbridge/linphone_push_key")
		}
		return
	}
	slog.Info("linphonepush sent", fields...)
}

// pushMu/pushRegs 保护按用户名缓存的推送参数；handleRegister 写，
// ringClients 读。不放进上游 Registrar，避免为加两个字段去覆盖上游文件。
func (s *Server) storePushParams(username string, pp pushParams, expires int) {
	if username == "" {
		return
	}
	s.pushMu.Lock()
	defer s.pushMu.Unlock()
	if s.pushRegs == nil {
		s.pushRegs = make(map[string]pushParams)
	}
	if expires <= 0 || !pp.valid() {
		delete(s.pushRegs, username)
		return
	}
	s.pushRegs[username] = pp
}

// pushFor 返回某用户当前注册的推送参数（没有则 ok=false）。
func (s *Server) pushFor(username string) (pushParams, bool) {
	s.pushMu.Lock()
	defer s.pushMu.Unlock()
	pp, ok := s.pushRegs[username]
	return pp, ok
}

// wakeLinphoneClients 对所有带 pn 参数的注册并发发推送。
// 返回是否至少发出一单（用于拉长 INVITE 重试窗口）。
func (s *Server) wakeLinphoneClients(callID string) bool {
	if s.linphonePushKey == "" {
		return false
	}
	var wg sync.WaitGroup
	sent := false
	s.pushMu.Lock()
	all := make(map[string]pushParams, len(s.pushRegs))
	for u, pp := range s.pushRegs {
		all[u] = pp
	}
	s.pushMu.Unlock()
	for _, pp := range all {
		if !pp.valid() {
			continue
		}
		sent = true
		wg.Add(1)
		go func(pp pushParams) {
			defer wg.Done()
			s.sendLinphonePush(pp, callID)
		}(pp)
	}
	if sent {
		slog.Info("linphonepush waking clients", "call", callID, "targets", len(all))
	}
	return sent
}

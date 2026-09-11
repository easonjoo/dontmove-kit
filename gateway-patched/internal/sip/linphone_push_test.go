package sip

// Linphone 推送参数解析与 Call-ID 清洗的回归测试
// （2026-09-11 引入 FlexiAPI 推送，wiki 示例的两种 Contact 形式都要认）。

import "testing"

func TestParsePushParamsRFC8599(t *testing.T) {
	// Linphone Android 5.3 wiki 示例（真实形态，iOS 同构，provider=apns）
	contact := `<sip:xxxx@192.168.0.1:48262;pn-prid=fCS-_c62SWmskRTsmm7Duc:VAV91bG5ePF60;pn-provider=apns;pn-param=ABCD1234.org.linphone.phone.voip;pn-silent=1;transport=tls>`
	pp, ok := parsePushParams(contact)
	if !ok {
		t.Fatal("expected push params to be found")
	}
	if pp.Provider != "apns" {
		t.Errorf("provider = %q, want apns", pp.Provider)
	}
	if pp.Param != "ABCD1234.org.linphone.phone.voip" {
		t.Errorf("param = %q", pp.Param)
	}
	if pp.Prid != "fCS-_c62SWmskRTsmm7Duc:VAV91bG5ePF60" {
		t.Errorf("prid = %q", pp.Prid)
	}
}

func TestParsePushParamsLegacy(t *testing.T) {
	// 旧式 Flexisip 参数（pn-type/pn-tok/app-id）
	contact := `<sip:u@1.2.3.4:1234;app-id=org.linphone.phone;pn-type=apple;pn-tok=ABA3D8A75E1A4F2C;transport=udp>`
	pp, ok := parsePushParams(contact)
	if !ok {
		t.Fatal("expected legacy push params to be found")
	}
	if pp.Provider != "apns" || pp.Prid != "ABA3D8A75E1A4F2C" || pp.Param != "org.linphone.phone" {
		t.Errorf("legacy parse = %+v", pp)
	}
}

func TestParsePushParamsAbsent(t *testing.T) {
	// YakPhone / 普通 SIP 客户端：没有 pn-*，绝不能误报
	contact := `<sip:iphone@192.168.1.50:5060>`
	if _, ok := parsePushParams(contact); ok {
		t.Fatal("expected no push params")
	}
	// 只有部分参数也不算
	if _, ok := parsePushParams(`<sip:u@h;pn-provider=apns>`); ok {
		t.Fatal("partial params must not count")
	}
}

func TestSanitizeCallID(t *testing.T) {
	// 我们自己的入呼 Call-ID 必须原样保留（INVITE 与推送要一致）
	for _, id := range []string{"in-7b44fd354a987dda", "in-1a2b3c4d5e6f", "in-abc-DEF-123"} {
		if got := sanitizeCallID(id); got != id {
			t.Errorf("sanitizeCallID(%q) = %q, want unchanged", id, got)
		}
	}
	if got := sanitizeCallID("in-a@b.c"); got != "in-a-b-c" {
		t.Errorf("sanitizeCallID at-sign = %q", got)
	}
}

func TestCleanPushParam(t *testing.T) {
	// Linphone 上报的 pn-param 带 &remote 后缀，FlexiAPI 只收字母数字/点/下划线
	if got := cleanPushParam("ABCD1234.org.linphone.phone.voip&remote"); got != "ABCD1234.org.linphone.phone.voip" {
		t.Errorf("cleanPushParam &remote = %q", got)
	}
	if got := cleanPushParam("org.linphone.phone.voip"); got != "org.linphone.phone.voip" {
		t.Errorf("cleanPushParam plain = %q", got)
	}
}

func TestPickCallPrid(t *testing.T) {
	voip := "574946470F13CCFDC3B585DE2150D30640FB81F7A62A0C8FEC3823BE0D0F8CCF:voip"
	remote := "dd99b4bd553945beded0d810b845bc592ff58e2197d3cd0d219e5bdb6106bab1:remote"
	// 双 token 合并上报：必须选 :voip 那个，且去掉 &
	if got := pickCallPrid(voip + "&" + remote); got != voip {
		t.Errorf("pickCallPrid dual = %q, want voip token", got)
	}
	// 单 token 原样保留
	if got := pickCallPrid(voip); got != voip {
		t.Errorf("pickCallPrid single = %q", got)
	}
	// 多 token 但都没有 :voip 后缀 → 回退第一个
	if got := pickCallPrid(remote + "&other:x"); got != remote {
		t.Errorf("pickCallPrid fallback = %q", got)
	}
}

package at

import "testing"

func TestClipNumber(t *testing.T) {
	cases := []struct {
		line string
		want string
	}{
		{`+CLIP: "13800138000",129,,,,0`, "13800138000"},
		{`+CLIP: "+8613800138000",129,,,,0`, "+8613800138000"},
		{`+CLIP: "",129,,,,0`, ""},
		{`+CLIP: "10010",145,,,,0`, "10010"},
	}
	for _, c := range cases {
		if got := clipNumber(c.line); got != c.want {
			t.Errorf("clipNumber(%q) = %q, want %q", c.line, got, c.want)
		}
	}
}

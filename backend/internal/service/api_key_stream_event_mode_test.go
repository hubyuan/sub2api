package service

import "testing"

func TestNormalizeOpenAIResponsesStreamEventMode(t *testing.T) {
	tests := []struct {
		name string
		mode string
		want string
	}{
		{name: "strict", mode: OpenAIResponsesStreamEventModeStrict, want: OpenAIResponsesStreamEventModeStrict},
		{name: "early event", mode: OpenAIResponsesStreamEventModeEarlyEvent, want: OpenAIResponsesStreamEventModeEarlyEvent},
		{name: "empty", mode: "", want: OpenAIResponsesStreamEventModeStrict},
		{name: "unknown", mode: "fast", want: OpenAIResponsesStreamEventModeStrict},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := NormalizeOpenAIResponsesStreamEventMode(tt.mode); got != tt.want {
				t.Fatalf("NormalizeOpenAIResponsesStreamEventMode(%q) = %q, want %q", tt.mode, got, tt.want)
			}
		})
	}
}

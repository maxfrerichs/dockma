package main

import (
	"encoding/json"
	"testing"
)

// The host (AgentMessage in Swift) decodes these exact shapes.
func TestDockerMessageJSON(t *testing.T) {
	for ready, want := range map[bool]string{
		true:  `{"type":"docker","ready":true}`,
		false: `{"type":"docker","ready":false}`,
	} {
		got, err := json.Marshal(dockerMessage(ready))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want {
			t.Errorf("dockerMessage(%v) = %s; want %s", ready, got, want)
		}
	}
}

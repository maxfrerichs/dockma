package main

import "testing"

func TestSubscribeCancelClosesChannel(t *testing.T) {
	w := newPortWatcher()
	updates, cancel := w.subscribe()
	if set := <-updates; len(set) != 0 {
		t.Fatalf("initial set = %v", set)
	}
	cancel()
	cancel() // idempotent
	if _, open := <-updates; open {
		t.Fatal("channel still open after cancel")
	}
	w.publish([]ForwardedPort{{Port: 80, Target: "127.0.0.1:80"}}) // must not panic
}

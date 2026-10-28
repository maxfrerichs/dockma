package main

import "testing"

func TestSubscribeCancelClosesChannel(t *testing.T) {
	w := newPortWatcher()
	updates, cancel := w.subscribe()
	if state := <-updates; len(state.Ports) != 0 || state.DockerReady {
		t.Fatalf("initial state = %+v", state)
	}
	cancel()
	cancel() // idempotent
	if _, open := <-updates; open {
		t.Fatal("channel still open after cancel")
	}
	w.publish([]forwardedPort{{Port: 80, Target: "127.0.0.1:80"}}) // must not panic
}

func TestSubscribeSeesReadinessChanges(t *testing.T) {
	w := newPortWatcher()
	updates, cancel := w.subscribe()
	defer cancel()
	<-updates
	w.setDockerReady(true)
	if state := <-updates; !state.DockerReady {
		t.Fatalf("after ready: %+v", state)
	}
	w.setDockerReady(true) // unchanged: no update
	select {
	case state := <-updates:
		t.Fatalf("unexpected update %+v", state)
	default:
	}
	w.setDockerReady(false)
	if state := <-updates; state.DockerReady {
		t.Fatalf("after not ready: %+v", state)
	}
}

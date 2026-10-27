package main

import (
	"testing"
	"time"
)

func TestEchoFilterMatchesOnlyTheGuestsOwnState(t *testing.T) {
	f := newEchoFilter()
	now := time.Unix(1000, 0)
	f.record(7, 1_793_102_875_233_538_782, 42, now)
	if !f.isEcho(7, 1_793_102_875_233_538_782, 42) {
		t.Error("the guest's own write was not recognised")
	}
	for _, c := range []struct {
		ino         uint64
		mtime, size int64
	}{
		{7, 1_793_102_875_233_538_783, 42}, // edited on the Mac afterwards
		{7, 1_793_102_875_233_538_782, 43},
		{8, 1_793_102_875_233_538_782, 42}, // another file
	} {
		if f.isEcho(c.ino, c.mtime, c.size) {
			t.Errorf("isEcho(%d, %d, %d) = true", c.ino, c.mtime, c.size)
		}
	}
}

func TestEchoFilterForgetsOldWrites(t *testing.T) {
	f := newEchoFilter()
	start := time.Unix(1000, 0)
	f.record(1, 10, 1, start)
	f.record(2, 20, 2, start.Add(echoWindow+time.Second)) // prunes ino 1
	if f.isEcho(1, 10, 1) {
		t.Error("a write older than echoWindow is still remembered")
	}
	if !f.isEcho(2, 20, 2) {
		t.Error("the recent write was pruned")
	}
}

func TestFileEventValid(t *testing.T) {
	for e, want := range map[fileEvent]bool{
		{Op: "M", Path: "/Users/me/a"}:      true,
		{Op: "C", Path: "/Users/me/a"}:      true,
		{Op: "D", Path: "/Users/me/a"}:      true,
		{Op: "X", Path: "/Users/me/a"}:      false,
		{Op: "M", Path: "relative"}:         false,
		{Op: "M", Path: "/Users/me/a\nM /"}: false,
		{Op: "M", Path: "/Users/me/a\x00"}:  false,
	} {
		if got := e.valid(); got != want {
			t.Errorf("%+v.valid() = %v, want %v", e, got, want)
		}
	}
}

func TestEnqueueDropsBatchesWhenTheQueueIsFull(t *testing.T) {
	f := &fileForwarder{queue: make(chan []fileEvent, 1)}
	batch := []fileEvent{{Op: "M", Path: "/Users/me/a"}}
	if !f.enqueue(batch) {
		t.Fatal("the first batch did not fit")
	}
	// No worker drains the queue: the reader must not block.
	if f.enqueue(batch) {
		t.Fatal("a batch beyond the queue was accepted")
	}
}

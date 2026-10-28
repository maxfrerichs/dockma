package filewaiter

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFileWaiterWakesOnCreate(t *testing.T) {
	dir := t.TempDir()
	w, err := New(dir, "docker.sock")
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	go func() {
		time.Sleep(50 * time.Millisecond)
		os.WriteFile(filepath.Join(dir, "other"), nil, 0o600)
		os.WriteFile(filepath.Join(dir, "docker.sock"), nil, 0o600)
	}()
	start := time.Now()
	if !w.Wait(5 * time.Second) {
		t.Fatal("wait timed out")
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("woke after %v", d)
	}
}

func TestFileWaiterTimesOut(t *testing.T) {
	w, err := New(t.TempDir(), "docker.sock")
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	if w.Wait(50 * time.Millisecond) {
		t.Fatal("woke without a create")
	}
}

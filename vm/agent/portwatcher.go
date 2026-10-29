package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"slices"
	"sync"
	"syscall"
	"time"

	"github.com/dockma/dockma/vm/agent/internal/filewaiter"
	"github.com/dockma/dockma/vm/agent/internal/logchange"
)

// watcherState is what the port watcher fans out: the published ports,
// whether dockerd's API answers, and the bind-mount sources to watch.
type watcherState struct {
	Ports       []forwardedPort
	DockerReady bool
	Watch       []string
}

// portWatcher tracks published ports and dockerd's readiness via the Docker
// API and fans the current state out to subscribers (one per host control
// connection).
type portWatcher struct {
	mu      sync.Mutex
	current watcherState
	subs    map[chan watcherState]struct{}
	client  *http.Client
	// share is the home share's guest path; "" means no bind mount is watched.
	share string
}

func newPortWatcher() *portWatcher {
	return &portWatcher{
		subs: map[chan watcherState]struct{}{},
		client: &http.Client{Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", dockerSocket)
			},
		}},
	}
}

// subscribe returns a channel that receives the current state immediately and
// every later change. The channel holds only the latest state. Cancelling
// closes it, which ends the subscriber's range loop.
func (w *portWatcher) subscribe() (<-chan watcherState, func()) {
	ch := make(chan watcherState, 1)
	w.mu.Lock()
	w.subs[ch] = struct{}{}
	ch <- w.current
	w.mu.Unlock()
	return ch, func() {
		w.mu.Lock()
		defer w.mu.Unlock()
		// update sends only under mu to channels still in subs.
		if _, ok := w.subs[ch]; ok {
			delete(w.subs, ch)
			close(ch)
		}
	}
}

// setDockerReady records whether dockerd's API answers.
func (w *portWatcher) setDockerReady(ready bool) {
	w.update(func(s *watcherState) { s.DockerReady = ready })
}

// update applies change and, if the state differs, sends it to subscribers.
func (w *portWatcher) update(change func(*watcherState)) {
	w.mu.Lock()
	defer w.mu.Unlock()
	next := w.current
	change(&next)
	if next.DockerReady == w.current.DockerReady && slices.Equal(next.Ports, w.current.Ports) && slices.Equal(next.Watch, w.current.Watch) {
		return
	}
	w.current = next
	for ch := range w.subs {
		select {
		case <-ch:
		default:
		}
		ch <- next
	}
}

func (w *portWatcher) run(ctx context.Context) {
	var errs logchange.Logger
	for {
		// Armed before the attempt, so a socket created during it still
		// wakes the wait below.
		waiter, waiterErr := filewaiter.New(filepath.Dir(dockerSocket), filepath.Base(dockerSocket))
		if waiterErr != nil {
			errs.Printf("port watcher: %v", waiterErr)
		}
		err := w.watch(ctx, func() {
			// Only a failed attempt waits on it; an open stream can last
			// hours, and the watch would queue every file created meanwhile.
			if waiter != nil {
				waiter.Close()
				waiter = nil
			}
		})
		w.setDockerReady(false)
		// dockerd not listening yet (boot, restart) is expected; other errors
		// are logged once each instead of every second.
		waiting := errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED)
		if err != nil && !waiting && !errors.Is(err, context.Canceled) {
			errs.Printf("port watcher: %v", err)
		}
		if waiting && waiter != nil {
			// dockerd creates its socket when it starts listening. The
			// timeout covers a create that raced the failed dial.
			waiter.Wait(2 * time.Second)
		} else {
			time.Sleep(time.Second)
		}
		if waiter != nil {
			waiter.Close()
		}
	}
}

// watch relists containers whenever a container event arrives on the
// /events stream. Relisting keeps the logic simple and always consistent.
// opened runs once the stream is open and dockerd's API answers.
func (w *portWatcher) watch(ctx context.Context, opened func()) error {
	filters := url.QueryEscape(`{"type":["container"]}`)
	req, _ := http.NewRequestWithContext(ctx, "GET", "http://docker/events?filters="+filters, nil)
	resp, err := w.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := w.relist(ctx); err != nil {
		return err
	}
	// The event stream is open and a request succeeded: the API answers.
	w.setDockerReady(true)
	opened()
	decoder := json.NewDecoder(resp.Body)
	for {
		var event struct {
			Action string `json:"Action"`
		}
		if err := decoder.Decode(&event); err != nil {
			return err
		}
		switch event.Action {
		case "start", "die", "destroy", "pause", "unpause", "restart":
			if err := w.relist(ctx); err != nil {
				return err
			}
		}
	}
}

func (w *portWatcher) relist(ctx context.Context) error {
	req, _ := http.NewRequestWithContext(ctx, "GET", "http://docker/containers/json", nil)
	resp, err := w.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("list containers: %s", resp.Status)
	}
	var containers []container
	if err := json.NewDecoder(resp.Body).Decode(&containers); err != nil {
		return err
	}
	w.update(func(s *watcherState) {
		s.Ports = publishedPorts(containers)
		s.Watch = watchedPaths(containers, w.share)
	})
	return nil
}

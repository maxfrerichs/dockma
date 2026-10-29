package fileevents

// Changes made on the Mac to watched bind-mount sources arrive from the host
// as "files" batches and become inotify events in the guest through the
// kernel hook (vm/kernel/dockma_notify.c). The Mac also reports the guest's
// own writes back; a fanotify recorder of those writes filters such echoes.

import (
	"errors"
	"log"
	"os"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"

	"github.com/dockma/dockma/vm/agent/internal/logchange"
)

const (
	notifyFile = "/proc/fs/dockma-notify"
	// shareFile holds the guest path of the home share; rcS writes it once the share is mounted.
	shareFile = "/run/dockma/home"
	// echoWindow is how long a guest write is remembered; the Mac's echo arrives within milliseconds.
	echoWindow = 30 * time.Second
	// fileQueueBatches is how many host batches wait for the hook; each is under 32 KiB.
	fileQueueBatches = 1024
)

// Event is one change on the Mac. MtimeNanos and Size are the file's
// after the change, from the host's lstat; a D has neither.
type Event struct {
	Op         string `json:"op"`
	Path       string `json:"path"`
	MtimeNanos int64  `json:"mtimeNanos,omitempty"`
	Size       int64  `json:"size,omitempty"`
}

// valid reports whether the event is one the hook understands. A newline
// would be cut by the hook, which strips one at the end of a write.
func (e Event) valid() bool {
	return (e.Op == "M" || e.Op == "C" || e.Op == "D") &&
		strings.HasPrefix(e.Path, "/") && !strings.ContainsAny(e.Path, "\n\x00")
}

// guestWrite is the state of a file after the guest last wrote it.
type guestWrite struct {
	mtimeNanos, size int64
	at               time.Time
}

// echoFilter remembers recent guest writes by guest inode number. The Mac's
// inode numbers differ from the guest's, but mtime and size match exactly.
type echoFilter struct {
	mu     sync.Mutex
	writes map[uint64]guestWrite
	pruned time.Time
}

func newEchoFilter() *echoFilter {
	return &echoFilter{writes: map[uint64]guestWrite{}}
}

// record notes a guest write and forgets writes older than echoWindow.
func (f *echoFilter) record(ino uint64, mtimeNanos, size int64, now time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.writes[ino] = guestWrite{mtimeNanos: mtimeNanos, size: size, at: now}
	if now.Sub(f.pruned) < echoWindow {
		return
	}
	for k, w := range f.writes {
		if now.Sub(w.at) > echoWindow {
			delete(f.writes, k)
		}
	}
	f.pruned = now
}

// isEcho reports whether the guest itself left the file in this state.
func (f *echoFilter) isEcho(ino uint64, mtimeNanos, size int64) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	w, ok := f.writes[ino]
	return ok && w.mtimeNanos == mtimeNanos && w.size == size
}

// recordGuestWrites records every file closed after writing on the share's
// filesystem, whichever mount namespace wrote it. It returns only on error.
func (f *echoFilter) recordGuestWrites(share string) error {
	fd, err := unix.FanotifyInit(unix.FAN_CLASS_NOTIF|unix.FAN_CLOEXEC, unix.O_RDONLY|unix.O_LARGEFILE|unix.O_CLOEXEC)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	if err := unix.FanotifyMark(fd, unix.FAN_MARK_ADD|unix.FAN_MARK_FILESYSTEM, unix.FAN_CLOSE_WRITE, unix.AT_FDCWD, share); err != nil {
		return err
	}
	var overflowed bool
	buf := make([]byte, 64*1024)
	for {
		n, err := unix.Read(fd, buf)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			return err
		}
		for off := 0; off+int(unix.FAN_EVENT_METADATA_LEN) <= n; {
			m := (*unix.FanotifyEventMetadata)(unsafe.Pointer(&buf[off]))
			if m.Event_len == 0 {
				break
			}
			if m.Mask&unix.FAN_Q_OVERFLOW != 0 && !overflowed {
				// Unrecorded writes only cost duplicate events.
				log.Print("file events: fanotify queue overflowed; some echoes of guest writes get through")
				overflowed = true
			}
			if m.Fd >= 0 {
				var st unix.Stat_t
				if unix.Fstat(int(m.Fd), &st) == nil {
					f.record(st.Ino, st.Mtim.Nano(), st.Size, time.Now())
				}
				unix.Close(int(m.Fd))
			}
			off += int(m.Event_len)
		}
	}
}

// Forwarder hands host file events to the kernel hook. Batches wait in
// queue for a worker, so the control reader never stalls behind the hook's
// virtiofs round trips and the host's writes never block.
type Forwarder struct {
	notify *os.File
	echoes *echoFilter
	errs   logchange.Logger
	queue  chan []Event
	// drops logs a full queue once per overflow; Enqueue runs on the control reader, errs on the worker.
	drops logchange.Logger
	// echoSeen logs the first echo dropped, which scripts/e2e.sh looks for.
	echoSeen sync.Once
}

// NewForwarder returns nil when there is no home share or the kernel has
// no hook, which turns the feature off.
func NewForwarder() *Forwarder {
	share := HomeShare()
	if share == "" {
		return nil
	}
	notify, err := os.OpenFile(notifyFile, os.O_WRONLY, 0)
	if err != nil {
		log.Printf("file events off: %v", err)
		return nil
	}
	f := &Forwarder{notify: notify, echoes: newEchoFilter(), queue: make(chan []Event, fileQueueBatches)}
	go func() {
		for batch := range f.queue {
			f.apply(batch)
		}
	}()
	go func() {
		// Without the recorder every guest write comes back as a duplicate event.
		if err := f.echoes.recordGuestWrites(share); err != nil {
			log.Printf("file events: recording guest writes: %v", err)
		}
	}()
	return f
}

// HomeShare returns the guest path of the home share, or "" if it isn't mounted.
func HomeShare() string {
	b, err := os.ReadFile(shareFile)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// Enqueue queues a batch for the worker and reports whether it fit. A dropped
// batch raises no events, and the guest serves those files from its cache
// until virtiofs revalidates them, as it did before file events.
func (f *Forwarder) Enqueue(events []Event) bool {
	select {
	case f.queue <- events:
		f.drops.Reset()
		return true
	default:
		f.drops.Printf("file events: queue full, dropping changes from the Mac")
		return false
	}
}

// apply raises the events for a batch, skipping the Mac's echoes of guest writes.
func (f *Forwarder) apply(events []Event) {
	for _, e := range events {
		if !e.valid() {
			f.errs.Printf("file events: ignoring %q %q", e.Op, e.Path)
			continue
		}
		// C goes first: the echo check's lstat caches the name, after which the
		// hook would take the file for one the guest already knew.
		if e.Op == "C" && !f.write("C", e.Path) {
			continue
		}
		if e.Op != "D" && f.isEcho(e) {
			f.echoSeen.Do(func() { log.Print("file events: dropping the Mac's echoes of guest writes") })
			continue
		}
		if e.Op == "D" {
			f.write("D", e.Path)
		} else {
			f.write("M", e.Path)
		}
	}
}

// write hands one change to the hook and reports whether the path was there.
func (f *Forwarder) write(op, path string) bool {
	// One change per write; the hook takes no trailing newline.
	_, err := f.notify.Write([]byte(op + " " + path))
	// Gone again by now, or no longer on the share: nothing to raise.
	if err != nil && !errors.Is(err, unix.ENOENT) && !errors.Is(err, unix.EXDEV) {
		f.errs.Printf("file events: %s %s: %v", op, path, err)
	}
	return err == nil
}

// isEcho reports whether a change on the Mac is the guest's own write coming
// back. A directory counts as one: M raises nothing for it.
func (f *Forwarder) isEcho(e Event) bool {
	var st unix.Stat_t
	if unix.Lstat(e.Path, &st) != nil {
		return false
	}
	if st.Mode&unix.S_IFMT == unix.S_IFDIR {
		return true
	}
	return f.echoes.isEcho(st.Ino, e.MtimeNanos, e.Size)
}

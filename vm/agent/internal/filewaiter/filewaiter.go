package filewaiter

import (
	"encoding/binary"
	"fmt"
	"os"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// Waiter wakes when a file with a given name appears in a directory, via
// inotify. Arm it before checking for the file, so a file created in between
// is not missed.
type Waiter struct {
	file *os.File
	name string
}

func New(dir, name string) (*Waiter, error) {
	fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
	if err != nil {
		return nil, fmt.Errorf("inotify: %w", err)
	}
	if _, err := unix.InotifyAddWatch(fd, dir, unix.IN_CREATE|unix.IN_MOVED_TO); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("inotify watch %s: %w", dir, err)
	}
	// A non-blocking descriptor gives a pollable File, so deadlines work.
	return &Waiter{file: os.NewFile(uintptr(fd), "inotify"), name: name}, nil
}

// Wait blocks until the file appears or timeout passes, and reports whether
// it appeared.
func (w *Waiter) Wait(timeout time.Duration) bool {
	w.file.SetReadDeadline(time.Now().Add(timeout))
	buf := make([]byte, 4096)
	for {
		n, err := w.file.Read(buf)
		if err != nil {
			return false
		}
		for _, name := range inotifyNames(buf[:n]) {
			if name == w.name {
				return true
			}
		}
	}
}

func (w *Waiter) Close() {
	w.file.Close()
}

// inotifyNames returns the file names of the inotify events in buf. Each
// event is a struct inotify_event: wd, mask, cookie, len (all 32-bit), then
// len bytes of NUL-padded name.
func inotifyNames(buf []byte) []string {
	var names []string
	for len(buf) >= unix.SizeofInotifyEvent {
		size := int(binary.NativeEndian.Uint32(buf[12:16]))
		end := unix.SizeofInotifyEvent + size
		if end > len(buf) {
			break
		}
		names = append(names, strings.TrimRight(string(buf[unix.SizeofInotifyEvent:end]), "\x00"))
		buf = buf[end:]
	}
	return names
}

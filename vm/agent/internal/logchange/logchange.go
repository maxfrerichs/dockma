// Package logchange logs a repeating failure once instead of on every retry.
package logchange

import (
	"fmt"
	"log"
)

// Logger logs a message only when it differs from the last one, so a
// failure that repeats every second is logged once.
type Logger struct {
	last string
}

// Printf logs the message unless it repeats the last one.
func (l *Logger) Printf(format string, args ...any) {
	if msg := fmt.Sprintf(format, args...); msg != l.last {
		log.Print(msg)
		l.last = msg
	}
}

// Reset makes the next message log even if it repeats the last one.
func (l *Logger) Reset() {
	l.last = ""
}

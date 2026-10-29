package controller

import (
	"k8s.io/client-go/tools/events"
)

// newFakeRecorder returns a buffered fake EventRecorder so the controller's
// r.Recorder.Eventf(...) calls don't block or need a real broadcaster in tests.
func newFakeRecorder() events.EventRecorder {
	return events.NewFakeRecorder(64)
}

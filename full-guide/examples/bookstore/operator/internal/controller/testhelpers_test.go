package controller

import (
	"k8s.io/client-go/tools/record"
)

// newFakeRecorder returns a buffered fake EventRecorder so the controller's
// r.Recorder.Event(...) calls don't block or need a real broadcaster in tests.
func newFakeRecorder() record.EventRecorder {
	return record.NewFakeRecorder(64)
}

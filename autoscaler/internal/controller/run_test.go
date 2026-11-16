package controller

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

// cancellingSource counts reads and cancels the loop on the nth.
type cancellingSource struct {
	calls  atomic.Int32
	cancel context.CancelFunc
	stopAt int32
}

func (s *cancellingSource) PendingJobs(context.Context) (int, error) {
	if s.calls.Add(1) == s.stopAt {
		s.cancel()
	}
	return 1, nil
}

func TestRunReconcilesEveryTickUntilDone(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	src := &cancellingSource{cancel: cancel, stopAt: 3}
	now := time.Now()
	c := newController(t, &fakeSource{}, &fakeScaler{}, &now)
	c.Source = src

	done := make(chan struct{})
	go func() { c.Run(ctx, time.Millisecond); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Run did not return after its context was cancelled")
	}
	if n := src.calls.Load(); n < 3 {
		t.Errorf("reconciled %d times, want at least 3 (once at start, then on ticks)", n)
	}
}

func TestRunWithDoneContextReconcilesOnce(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	src := &cancellingSource{cancel: func() {}, stopAt: -1}
	now := time.Now()
	c := newController(t, &fakeSource{}, &fakeScaler{}, &now)
	c.Source = src

	start := time.Now()
	c.Run(ctx, time.Hour)
	if n := src.calls.Load(); n != 1 {
		t.Errorf("reconciled %d times, want exactly 1", n)
	}
	if time.Since(start) > 5*time.Second {
		t.Error("Run waited for a tick instead of returning on a done context")
	}
}

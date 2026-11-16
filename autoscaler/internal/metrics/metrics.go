// Package metrics exposes the autoscaler's state in the Prometheus text
// exposition format (version 0.0.4) without third-party dependencies.
package metrics

import (
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

// Recorder holds the latest values. All methods are safe for concurrent use.
type Recorder struct {
	mu              sync.Mutex
	pending         int
	desired         int
	current         int
	businessHours   bool
	reconciles      uint64
	errors          map[string]uint64 // by stage: queue, scale_get, scale_set
	scaleEvents     map[string]uint64 // by direction: up, down
	lastSuccess     time.Time
	lastReconcileMS float64
	max             int
}

// New returns an empty Recorder.
func New() *Recorder {
	return &Recorder{errors: map[string]uint64{}, scaleEvents: map[string]uint64{}}
}

// Observe records a completed reconcile.
func (r *Recorder) Observe(pending, desired, current int, business bool, took time.Duration, at time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pending, r.desired, r.current, r.businessHours = pending, desired, current, business
	r.reconciles++
	r.lastSuccess = at
	r.lastReconcileMS = float64(took) / float64(time.Millisecond)
}

// SetMax records the configured ceiling so alerts can tell when the pool is
// pinned at its limit.
func (r *Recorder) SetMax(n int) {
	r.mu.Lock()
	r.max = n
	r.mu.Unlock()
}

// Error counts a failure at the given stage.
func (r *Recorder) Error(stage string) {
	r.mu.Lock()
	r.errors[stage]++
	r.mu.Unlock()
}

// Scaled counts a change in the warm pool's size.
func (r *Recorder) Scaled(from, to int) {
	dir := "up"
	if to < from {
		dir = "down"
	}
	r.mu.Lock()
	r.scaleEvents[dir]++
	r.mu.Unlock()
}

// LastSuccess returns the time of the last successful reconcile.
func (r *Recorder) LastSuccess() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lastSuccess
}

// Write writes all metrics in text exposition format.
func (r *Recorder) Write(w io.Writer) {
	r.mu.Lock()
	defer r.mu.Unlock()

	gauge := func(name, help string, v float64) {
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s gauge\n%s %g\n", name, help, name, name, v)
	}
	gauge("warmpool_pending_jobs", "Pending CI jobs that match this fleet's runner tags.", float64(r.pending))
	gauge("warmpool_desired_replicas", "Warm-pool size after policy and scale-down stabilization.", float64(r.desired))
	gauge("warmpool_current_replicas", "Warm-pool size last read from the Deployment.", float64(r.current))
	gauge("warmpool_max_replicas", "Configured warm-pool ceiling.", float64(r.max))
	gauge("warmpool_business_hours", "1 inside the configured business-hours schedule, else 0.", b2f(r.businessHours))
	gauge("warmpool_reconcile_duration_milliseconds", "Duration of the last successful reconcile.", r.lastReconcileMS)
	if !r.lastSuccess.IsZero() {
		gauge("warmpool_last_success_timestamp_seconds", "Unix time of the last successful reconcile.",
			float64(r.lastSuccess.UnixNano())/1e9)
	}

	fmt.Fprintf(w, "# HELP warmpool_reconciles_total Successful reconcile loops.\n# TYPE warmpool_reconciles_total counter\nwarmpool_reconciles_total %d\n", r.reconciles)

	fmt.Fprint(w, "# HELP warmpool_errors_total Reconcile failures by stage.\n# TYPE warmpool_errors_total counter\n")
	for _, stage := range []string{"queue", "scale_get", "scale_set"} {
		fmt.Fprintf(w, "warmpool_errors_total{stage=%q} %d\n", stage, r.errors[stage])
	}
	fmt.Fprint(w, "# HELP warmpool_scale_events_total Warm-pool resizes by direction.\n# TYPE warmpool_scale_events_total counter\n")
	for _, dir := range []string{"up", "down"} {
		fmt.Fprintf(w, "warmpool_scale_events_total{direction=%q} %d\n", dir, r.scaleEvents[dir])
	}
}

// Handler serves the metrics page.
func (r *Recorder) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		r.Write(w)
	})
}

func b2f(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

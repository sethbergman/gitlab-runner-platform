package controller

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/sethbergman/gitlab-runner-platform/autoscaler/internal/metrics"
	"github.com/sethbergman/gitlab-runner-platform/autoscaler/internal/policy"
)

type fakeSource struct {
	pending int
	err     error
}

func (f *fakeSource) PendingJobs(context.Context) (int, error) { return f.pending, f.err }

type fakeScaler struct {
	replicas int
	sets     int
	getErr   error
}

func (f *fakeScaler) GetReplicas(context.Context, string, string) (int, error) {
	return f.replicas, f.getErr
}

func (f *fakeScaler) SetReplicas(_ context.Context, _, _ string, n int) error {
	f.replicas = n
	f.sets++
	return nil
}

func newController(t *testing.T, src *fakeSource, sc *fakeScaler, now *time.Time) *Controller {
	t.Helper()
	sched, err := policy.ParseSchedule("never", time.UTC) // off-hours: no headroom, floor 0
	if err != nil {
		t.Fatal(err)
	}
	return &Controller{
		Source:     src,
		Scaler:     sc,
		Policy:     policy.Config{JobsPerReplica: 1, Max: 50},
		Schedule:   sched,
		Stabilizer: policy.NewStabilizer(10 * time.Minute),
		Namespace:  "ci-system",
		Deployment: "warm-pool",
		Metrics:    metrics.New(),
		Log:        slog.New(slog.NewTextHandler(io.Discard, nil)),
		Now:        func() time.Time { return *now },
	}
}

func TestScaleUpThenHoldThenScaleDown(t *testing.T) {
	now := time.Date(2026, 1, 5, 12, 0, 0, 0, time.UTC)
	src, sc := &fakeSource{pending: 12}, &fakeScaler{replicas: 0}
	c := newController(t, src, sc, &now)
	ctx := context.Background()

	if err := c.Reconcile(ctx); err != nil {
		t.Fatal(err)
	}
	if sc.replicas != 12 {
		t.Fatalf("after burst replicas = %d, want 12", sc.replicas)
	}

	src.pending = 0
	now = now.Add(5 * time.Minute)
	_ = c.Reconcile(ctx)
	if sc.replicas != 12 {
		t.Fatalf("inside stabilization window replicas = %d, want 12 held", sc.replicas)
	}

	now = now.Add(6 * time.Minute)
	_ = c.Reconcile(ctx)
	if sc.replicas != 0 {
		t.Fatalf("after window replicas = %d, want 0", sc.replicas)
	}
	if sc.sets != 2 {
		t.Fatalf("SetReplicas called %d times, want 2 (no-op loops must not patch)", sc.sets)
	}
}

func TestQueueErrorFailsStatic(t *testing.T) {
	now := time.Now()
	src, sc := &fakeSource{err: errors.New("gitlab down")}, &fakeScaler{replicas: 6}
	c := newController(t, src, sc, &now)

	if err := c.Reconcile(context.Background()); err == nil {
		t.Fatal("want error")
	}
	if sc.replicas != 6 || sc.sets != 0 {
		t.Fatalf("warm pool changed on a blind signal: replicas=%d sets=%d", sc.replicas, sc.sets)
	}
	var buf bytes.Buffer
	c.Metrics.Write(&buf)
	if !strings.Contains(buf.String(), `warmpool_errors_total{stage="queue"} 1`) {
		t.Fatalf("queue error not counted:\n%s", buf.String())
	}
}

func TestScaleGetErrorIsCounted(t *testing.T) {
	now := time.Now()
	src, sc := &fakeSource{pending: 3}, &fakeScaler{getErr: errors.New("forbidden")}
	c := newController(t, src, sc, &now)
	if err := c.Reconcile(context.Background()); err == nil {
		t.Fatal("want error")
	}
	var buf bytes.Buffer
	c.Metrics.Write(&buf)
	if !strings.Contains(buf.String(), `warmpool_errors_total{stage="scale_get"} 1`) {
		t.Fatalf("scale_get error not counted:\n%s", buf.String())
	}
}

func TestMetricsAfterReconcile(t *testing.T) {
	now := time.Now()
	c := newController(t, &fakeSource{pending: 4}, &fakeScaler{}, &now)
	if err := c.Reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	c.Metrics.Write(&buf)
	for _, want := range []string{
		"warmpool_pending_jobs 4",
		"warmpool_desired_replicas 4",
		"warmpool_current_replicas 4",
		`warmpool_scale_events_total{direction="up"} 1`,
		"warmpool_reconciles_total 1",
	} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("metrics missing %q", want)
		}
	}
}

// Package controller runs the reconcile loop: read the queue, decide a size,
// and resize the warm pool.
package controller

import (
	"context"
	"log/slog"
	"time"

	"github.com/sethbergman/gitlab-runner-platform/autoscaler/internal/metrics"
	"github.com/sethbergman/gitlab-runner-platform/autoscaler/internal/policy"
)

// QueueSource reports how many jobs are waiting for this fleet.
type QueueSource interface {
	PendingJobs(ctx context.Context) (int, error)
}

// Scaler reads and sets the warm pool's replica count.
type Scaler interface {
	GetReplicas(ctx context.Context, namespace, name string) (int, error)
	SetReplicas(ctx context.Context, namespace, name string, replicas int) error
}

// Controller wires the pieces together.
type Controller struct {
	Source     QueueSource
	Scaler     Scaler
	Policy     policy.Config
	Schedule   policy.Schedule
	Stabilizer *policy.Stabilizer
	Namespace  string
	Deployment string
	Metrics    *metrics.Recorder
	Log        *slog.Logger
	Now        func() time.Time
}

// Reconcile performs one pass. It fails static: if the queue cannot be read,
// the warm pool keeps its current size rather than scaling on a blind signal.
func (c *Controller) Reconcile(ctx context.Context) error {
	start := c.now()

	pending, err := c.Source.PendingJobs(ctx)
	if err != nil {
		c.Metrics.Error("queue")
		c.Log.Warn("queue read failed; holding current size", "err", err)
		return err
	}

	business := c.Schedule.Active(start)
	target := policy.Desired(c.Policy, pending, business)
	stable := c.Stabilizer.Next(start, target)

	current, err := c.Scaler.GetReplicas(ctx, c.Namespace, c.Deployment)
	if err != nil {
		c.Metrics.Error("scale_get")
		return err
	}

	if stable != current {
		if err := c.Scaler.SetReplicas(ctx, c.Namespace, c.Deployment, stable); err != nil {
			c.Metrics.Error("scale_set")
			return err
		}
		c.Metrics.Scaled(current, stable)
		c.Log.Info("resized warm pool",
			"from", current, "to", stable, "target", target,
			"pending", pending, "business_hours", business)
		current = stable
	}

	end := c.now()
	c.Metrics.Observe(pending, stable, current, business, end.Sub(start), end)
	c.Log.Debug("reconciled", "pending", pending, "target", target, "stable", stable, "current", current)
	return nil
}

// Run reconciles on every tick until ctx is done.
func (c *Controller) Run(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		_ = c.Reconcile(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (c *Controller) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

// Package policy turns a CI queue signal into a warm-pool size.
//
// The policy is deliberately small and pure so it can be reasoned about and
// tested without a cluster: given how many jobs are waiting and whether we are
// inside business hours, it returns how many placeholder replicas should be
// running. A Stabilizer then smooths scale-down the same way the Kubernetes
// HorizontalPodAutoscaler does, so a brief lull does not release nodes that
// the next pipeline wave will need.
package policy

import (
	"errors"
	"fmt"
	"time"
)

// Config bounds the warm pool.
type Config struct {
	// JobsPerReplica is how many pending jobs one warm replica is sized to
	// absorb. A replica reserves roughly one job pod's requests, so 1 is the
	// conservative default; raise it if job pods are small relative to the
	// placeholder.
	JobsPerReplica int
	// Headroom is added during business hours so the first jobs of a new
	// wave never wait for a node, even when the queue is empty.
	Headroom int
	// MinBusiness and MinOffHours are floors for each part of the schedule.
	MinBusiness int
	MinOffHours int
	// Max caps spend no matter how deep the queue gets.
	Max int
}

// Validate reports configuration that would make Desired meaningless.
func (c Config) Validate() error {
	var errs []error
	if c.JobsPerReplica < 1 {
		errs = append(errs, errors.New("jobs per replica must be >= 1"))
	}
	if c.Headroom < 0 || c.MinBusiness < 0 || c.MinOffHours < 0 || c.Max < 0 {
		errs = append(errs, errors.New("headroom, minimums and max must be >= 0"))
	}
	if c.MinBusiness > c.Max || c.MinOffHours > c.Max {
		errs = append(errs, fmt.Errorf("minimums (%d business, %d off-hours) exceed max %d",
			c.MinBusiness, c.MinOffHours, c.Max))
	}
	return errors.Join(errs...)
}

// Desired returns the target warm-pool size for the current signal.
func Desired(c Config, pending int, businessHours bool) int {
	if pending < 0 {
		pending = 0
	}
	floor := c.MinOffHours
	want := ceilDiv(pending, c.JobsPerReplica)
	if businessHours {
		floor = c.MinBusiness
		want += c.Headroom
	}
	return clamp(want, floor, c.Max)
}

func ceilDiv(a, b int) int { return (a + b - 1) / b }

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// Stabilizer delays scale-down: it returns the highest recommendation seen
// within the window. Scale-up takes effect immediately because the newest
// recommendation is always part of that maximum.
type Stabilizer struct {
	window time.Duration
	recs   []recommendation
}

type recommendation struct {
	at       time.Time
	replicas int
}

// NewStabilizer returns a Stabilizer with the given scale-down window. A zero
// window disables stabilization.
func NewStabilizer(window time.Duration) *Stabilizer {
	return &Stabilizer{window: window}
}

// Next records a recommendation and returns the stabilized value.
func (s *Stabilizer) Next(now time.Time, replicas int) int {
	s.recs = append(s.recs, recommendation{at: now, replicas: replicas})
	cutoff := now.Add(-s.window)
	kept := s.recs[:0]
	for _, r := range s.recs {
		if !r.at.Before(cutoff) {
			kept = append(kept, r)
		}
	}
	s.recs = kept

	highest := replicas
	for _, r := range s.recs {
		if r.replicas > highest {
			highest = r.replicas
		}
	}
	return highest
}

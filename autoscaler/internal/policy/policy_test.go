package policy

import (
	"testing"
	"time"
)

var cfg = Config{JobsPerReplica: 2, Headroom: 2, MinBusiness: 3, MinOffHours: 0, Max: 20}

func TestDesired(t *testing.T) {
	tests := []struct {
		name     string
		pending  int
		business bool
		want     int
	}{
		{"empty queue off-hours scales to zero", 0, false, 0},
		{"empty queue business hours keeps floor", 0, true, 3},
		{"rounds up partial replicas", 3, false, 2},
		{"adds headroom in business hours", 3, true, 4},
		{"caps at max", 500, true, 20},
		{"negative pending is treated as zero", -4, false, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Desired(cfg, tt.pending, tt.business); got != tt.want {
				t.Fatalf("Desired(%d, %v) = %d, want %d", tt.pending, tt.business, got, tt.want)
			}
		})
	}
}

func TestValidate(t *testing.T) {
	if err := cfg.Validate(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
	bad := []Config{
		{JobsPerReplica: 0, Max: 1},
		{JobsPerReplica: 1, MinBusiness: 5, Max: 2},
		{JobsPerReplica: 1, Headroom: -1, Max: 2},
	}
	for _, c := range bad {
		if err := c.Validate(); err == nil {
			t.Errorf("Validate(%+v) = nil, want error", c)
		}
	}
}

func TestStabilizerScalesUpImmediatelyAndDownAfterWindow(t *testing.T) {
	s := NewStabilizer(5 * time.Minute)
	t0 := time.Date(2026, 1, 5, 9, 0, 0, 0, time.UTC)

	if got := s.Next(t0, 2); got != 2 {
		t.Fatalf("first = %d, want 2", got)
	}
	if got := s.Next(t0.Add(time.Minute), 10); got != 10 {
		t.Fatalf("scale-up = %d, want 10 immediately", got)
	}
	if got := s.Next(t0.Add(2*time.Minute), 1); got != 10 {
		t.Fatalf("inside window = %d, want 10 held", got)
	}
	// The 10 was recorded at t0+1m; it ages out after t0+6m.
	if got := s.Next(t0.Add(6*time.Minute+time.Second), 1); got != 1 {
		t.Fatalf("after window = %d, want 1", got)
	}
}

func TestStabilizerZeroWindow(t *testing.T) {
	s := NewStabilizer(0)
	now := time.Now()
	s.Next(now, 8)
	if got := s.Next(now.Add(time.Second), 1); got != 1 {
		t.Fatalf("zero window = %d, want 1", got)
	}
}

func TestSchedule(t *testing.T) {
	chicago, err := time.LoadLocation("America/Chicago")
	if err != nil {
		t.Skip("tzdata not available")
	}
	s, err := ParseSchedule("Mon-Fri 07:00-19:00", chicago)
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		at   time.Time
		want bool
	}{
		{time.Date(2026, 3, 2, 7, 0, 0, 0, chicago), true},   // Monday open
		{time.Date(2026, 3, 2, 18, 59, 0, 0, chicago), true}, // Monday last minute
		{time.Date(2026, 3, 2, 19, 0, 0, 0, chicago), false}, // end is exclusive
		{time.Date(2026, 3, 7, 10, 0, 0, 0, chicago), false}, // Saturday
		{time.Date(2026, 3, 2, 13, 0, 0, 0, time.UTC), true}, // 07:00 Chicago (CST)
	}
	for _, c := range cases {
		if got := s.Active(c.at); got != c.want {
			t.Errorf("Active(%s) = %v, want %v", c.at, got, c.want)
		}
	}
}

func TestScheduleWrappingDaysAndSpecials(t *testing.T) {
	s, err := ParseSchedule("Fri-Mon 00:00-23:59", time.UTC)
	if err != nil {
		t.Fatal(err)
	}
	if !s.Active(time.Date(2026, 3, 8, 12, 0, 0, 0, time.UTC)) { // Sunday
		t.Error("Sunday should be inside Fri-Mon")
	}
	if s.Active(time.Date(2026, 3, 4, 12, 0, 0, 0, time.UTC)) { // Wednesday
		t.Error("Wednesday should be outside Fri-Mon")
	}

	always, _ := ParseSchedule("always", nil)
	never, _ := ParseSchedule("never", nil)
	now := time.Now()
	if !always.Active(now) || never.Active(now) {
		t.Error("always/never misbehave")
	}
}

func TestParseScheduleErrors(t *testing.T) {
	for _, spec := range []string{"", "Mon-Fri", "Funday 07:00-19:00", "Mon-Fri 19:00-07:00", "Mon-Fri 7am-7pm"} {
		if _, err := ParseSchedule(spec, time.UTC); err == nil {
			t.Errorf("ParseSchedule(%q) = nil error", spec)
		}
	}
}

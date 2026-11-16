package policy

import (
	"fmt"
	"strings"
	"time"
)

// Schedule describes when business hours apply, e.g. "Mon-Fri 07:00-19:00"
// in a given time zone. The special values "always" and "never" are accepted.
type Schedule struct {
	days       [7]bool // indexed by time.Weekday
	start, end int     // minutes after midnight, start < end
	always     bool
	loc        *time.Location
}

var weekdays = map[string]time.Weekday{
	"sun": time.Sunday, "mon": time.Monday, "tue": time.Tuesday, "wed": time.Wednesday,
	"thu": time.Thursday, "fri": time.Friday, "sat": time.Saturday,
}

// ParseSchedule parses "Mon-Fri 07:00-19:00", "Mon,Wed,Fri 09:00-17:00",
// "always" or "never".
func ParseSchedule(spec string, loc *time.Location) (Schedule, error) {
	if loc == nil {
		loc = time.UTC
	}
	s := Schedule{loc: loc}
	switch strings.ToLower(strings.TrimSpace(spec)) {
	case "always":
		s.always = true
		return s, nil
	case "never":
		return s, nil
	}

	fields := strings.Fields(spec)
	if len(fields) != 2 {
		return s, fmt.Errorf("schedule %q: want \"<days> <HH:MM>-<HH:MM>\"", spec)
	}
	if err := s.parseDays(fields[0]); err != nil {
		return s, fmt.Errorf("schedule %q: %w", spec, err)
	}
	from, to, ok := strings.Cut(fields[1], "-")
	if !ok {
		return s, fmt.Errorf("schedule %q: hours must look like 07:00-19:00", spec)
	}
	var err error
	if s.start, err = parseClock(from); err != nil {
		return s, fmt.Errorf("schedule %q: %w", spec, err)
	}
	if s.end, err = parseClock(to); err != nil {
		return s, fmt.Errorf("schedule %q: %w", spec, err)
	}
	if s.start >= s.end {
		return s, fmt.Errorf("schedule %q: start must be before end (overnight windows are not supported)", spec)
	}
	return s, nil
}

func (s *Schedule) parseDays(spec string) error {
	for _, part := range strings.Split(strings.ToLower(spec), ",") {
		from, to, isRange := strings.Cut(part, "-")
		a, ok := weekdays[from]
		if !ok {
			return fmt.Errorf("unknown day %q", from)
		}
		if !isRange {
			s.days[a] = true
			continue
		}
		b, ok := weekdays[to]
		if !ok {
			return fmt.Errorf("unknown day %q", to)
		}
		for d := a; ; d = (d + 1) % 7 {
			s.days[d] = true
			if d == b {
				break
			}
		}
	}
	return nil
}

func parseClock(v string) (int, error) {
	t, err := time.Parse("15:04", v)
	if err != nil {
		return 0, fmt.Errorf("bad time %q (want HH:MM)", v)
	}
	return t.Hour()*60 + t.Minute(), nil
}

// Active reports whether t falls inside business hours.
func (s Schedule) Active(t time.Time) bool {
	if s.always {
		return true
	}
	local := t.In(s.loc)
	if !s.days[local.Weekday()] {
		return false
	}
	m := local.Hour()*60 + local.Minute()
	return m >= s.start && m < s.end
}

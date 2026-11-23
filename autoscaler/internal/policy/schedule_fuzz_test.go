package policy

import (
	"strings"
	"testing"
	"time"
)

// FuzzParseSchedule checks that whatever ParseSchedule accepts is a schedule
// Active agrees with: a window inside one day, open on exactly the parsed
// days, from its first minute through its last and not a minute either side.
func FuzzParseSchedule(f *testing.F) {
	for _, spec := range []string{
		"Mon-Fri 07:00-19:00",
		"Mon,Wed,Fri 09:00-17:00",
		"Fri-Mon 00:00-23:59",
		"sat-sat 23:58-23:59",
		"always",
		" NEVER ",
		"Mon-Fri 19:00-07:00",
		"Mon 7:00-9:05",
		"mon-tue-wed 07:00-08:00",
		"Mon, 07:00-08:00",
		"Mon 24:00-25:00",
		"Mon\t07:00-08:00",
		"",
	} {
		f.Add(spec)
	}
	sunday := time.Date(2026, time.January, 4, 0, 0, 0, 0, time.UTC)

	f.Fuzz(func(t *testing.T, spec string) {
		s, err := ParseSchedule(spec, time.UTC)
		if err != nil {
			return
		}
		special := strings.ToLower(strings.TrimSpace(spec))
		if special == "always" || special == "never" {
			for h := 0; h < 7*24; h++ {
				if s.Active(sunday.Add(time.Duration(h)*time.Hour)) != (special == "always") {
					t.Fatalf("%q: Active disagrees at hour %d of the week", spec, h)
				}
			}
			return
		}
		if s.always || s.start < 0 || s.start >= s.end || s.end > 24*60-1 {
			t.Fatalf("%q parsed to always=%v start=%d end=%d", spec, s.always, s.start, s.end)
		}
		open := 0
		for d := 0; d < 7; d++ {
			day := sunday.AddDate(0, 0, d)
			at := func(minute int) bool { return s.Active(day.Add(time.Duration(minute) * time.Minute)) }
			want := s.days[d]
			if want {
				open++
			}
			if at(s.start) != want || at(s.end-1) != want {
				t.Fatalf("%q: on %s Active at the window's edges disagrees with days=%v", spec, day.Weekday(), want)
			}
			if at(s.end) || (s.start > 0 && at(s.start-1)) {
				t.Fatalf("%q: Active outside the window on %s", spec, day.Weekday())
			}
		}
		if open == 0 {
			t.Fatalf("%q parsed with no days", spec)
		}
	})
}

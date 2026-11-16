package metrics

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func sample() *Recorder {
	r := New()
	r.SetMax(40)
	r.Error("queue")
	r.Error("queue")
	r.Scaled(2, 5)
	r.Scaled(5, 1)
	r.Observe(7, 9, 9, true, 1500*time.Millisecond, time.Unix(1700000000, 0))
	return r
}

func exposition(r *Recorder) string {
	var buf bytes.Buffer
	r.Write(&buf)
	return buf.String()
}

var (
	nameRE   = regexp.MustCompile(`^[a-zA-Z_:][a-zA-Z0-9_:]*$`)
	labelsRE = regexp.MustCompile(`^\{[a-zA-Z_][a-zA-Z0-9_]*="[^"\\]*"(,[a-zA-Z_][a-zA-Z0-9_]*="[^"\\]*")*\}$`)
	// Units promtool's linter rejects in favour of their base unit.
	nonBaseUnits = map[string]bool{
		"milliseconds": true, "microseconds": true, "nanoseconds": true,
		"minutes": true, "hours": true, "days": true, "weeks": true,
		"kilobytes": true, "megabytes": true, "gigabytes": true, "percent": true,
	}
)

// parse returns every sample keyed by name and labels, checking the shape
// of the exposition on the way: each family has one HELP and one TYPE line
// before its samples, counters end in _total, names use base units, and
// values are numbers.
func parse(t *testing.T, out string) map[string]float64 {
	t.Helper()
	help, typ := map[string]bool{}, map[string]string{}
	values := map[string]float64{}
	for _, line := range strings.Split(strings.TrimSuffix(out, "\n"), "\n") {
		switch {
		case strings.HasPrefix(line, "# HELP "):
			f := strings.SplitN(strings.TrimPrefix(line, "# HELP "), " ", 2)
			if len(f) != 2 || f[1] == "" {
				t.Errorf("HELP without text: %q", line)
				continue
			}
			if help[f[0]] {
				t.Errorf("HELP repeated for %s", f[0])
			}
			help[f[0]] = true
		case strings.HasPrefix(line, "# TYPE "):
			f := strings.Fields(strings.TrimPrefix(line, "# TYPE "))
			if len(f) != 2 || (f[1] != "gauge" && f[1] != "counter") {
				t.Errorf("bad TYPE line %q", line)
				continue
			}
			if f[1] == "counter" && !strings.HasSuffix(f[0], "_total") {
				t.Errorf("counter %s should end in _total", f[0])
			}
			typ[f[0]] = f[1]
		case strings.HasPrefix(line, "#"):
			t.Errorf("unexpected comment %q", line)
		default:
			i := strings.LastIndex(line, " ")
			if i < 0 {
				t.Errorf("not a sample: %q", line)
				continue
			}
			key, val := line[:i], line[i+1:]
			name := key
			if j := strings.IndexByte(key, '{'); j >= 0 {
				name = key[:j]
				if !labelsRE.MatchString(key[j:]) {
					t.Errorf("bad labels in %q", line)
				}
			}
			if !nameRE.MatchString(name) {
				t.Errorf("bad metric name in %q", line)
			}
			for _, word := range strings.Split(name, "_") {
				if nonBaseUnits[word] {
					t.Errorf("%s uses %s; use the base unit", name, word)
				}
			}
			if !help[name] || typ[name] == "" {
				t.Errorf("sample %s appears before its HELP and TYPE", name)
			}
			v, err := strconv.ParseFloat(val, 64)
			if err != nil {
				t.Errorf("value of %s: %v", key, err)
			}
			if _, dup := values[key]; dup {
				t.Errorf("duplicate sample %s", key)
			}
			values[key] = v
		}
	}
	return values
}

func TestWriteReportsEveryValue(t *testing.T) {
	got := parse(t, exposition(sample()))
	want := map[string]float64{
		"warmpool_pending_jobs":                         7,
		"warmpool_desired_replicas":                     9,
		"warmpool_current_replicas":                     9,
		"warmpool_max_replicas":                         40,
		"warmpool_business_schedule_active":             1,
		"warmpool_reconcile_duration_seconds":           1.5,
		"warmpool_last_success_timestamp_seconds":       1700000000,
		"warmpool_reconciles_total":                     1,
		`warmpool_errors_total{stage="queue"}`:          2,
		`warmpool_errors_total{stage="scale_get"}`:      0,
		`warmpool_errors_total{stage="scale_set"}`:      0,
		`warmpool_scale_events_total{direction="up"}`:   1,
		`warmpool_scale_events_total{direction="down"}`: 1,
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %g, want %g", k, got[k], v)
		}
	}
	for k := range got {
		if _, ok := want[k]; !ok {
			t.Errorf("unexpected sample %s", k)
		}
	}
}

func TestBeforeFirstReconcile(t *testing.T) {
	r := New()
	if !r.LastSuccess().IsZero() {
		t.Error("LastSuccess should be zero before any reconcile")
	}
	got := parse(t, exposition(r))
	if _, ok := got["warmpool_last_success_timestamp_seconds"]; ok {
		t.Error("last-success timestamp should not be exposed before a reconcile")
	}
	if got["warmpool_business_schedule_active"] != 0 || got["warmpool_reconciles_total"] != 0 {
		t.Errorf("unexpected initial values: %v", got)
	}
	at := time.Unix(1700000000, 0)
	r.Observe(0, 0, 0, false, 0, at)
	if !r.LastSuccess().Equal(at) {
		t.Errorf("LastSuccess = %v, want %v", r.LastSuccess(), at)
	}
}

// Every metric the alert rules and the Grafana dashboard query must be one the
// autoscaler exposes, so a rename here cannot silently blank a panel.
func TestDashboardAndRulesQueryExposedMetrics(t *testing.T) {
	exposed := map[string]bool{}
	for key := range parse(t, exposition(sample())) {
		name, _, _ := strings.Cut(key, "{")
		exposed[name] = true
	}
	ref := regexp.MustCompile(`\bwarmpool_[a-z0-9_]+`)
	for _, path := range []string{
		"../../../observability/prometheus-rules.yaml",
		"../../../observability/grafana/runner-platform.json",
	} {
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, name := range ref.FindAllString(string(b), -1) {
			if !exposed[name] {
				t.Errorf("%s queries %s, which the autoscaler does not expose", path, name)
			}
		}
	}
}

func TestHandler(t *testing.T) {
	rec := httptest.NewRecorder()
	sample().Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain; version=0.0.4") {
		t.Errorf("Content-Type = %q", ct)
	}
	if !strings.Contains(rec.Body.String(), "warmpool_reconciles_total 1\n") {
		t.Errorf("body missing reconcile count:\n%s", rec.Body.String())
	}
}

func TestConcurrentUse(t *testing.T) {
	r := New()
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for n := 0; n < 100; n++ {
				r.Observe(n, n, n, i%2 == 0, time.Millisecond, time.Now())
				r.Error("queue")
				r.Scaled(n, n+1)
				r.SetMax(i)
				r.Write(io.Discard)
				_ = r.LastSuccess()
			}
		}(i)
	}
	wg.Wait()
	got := parse(t, exposition(r))
	if got["warmpool_reconciles_total"] != 800 || got[`warmpool_errors_total{stage="queue"}`] != 800 {
		t.Errorf("counts after concurrent use: %v", got)
	}
}

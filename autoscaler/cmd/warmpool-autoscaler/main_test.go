package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sethbergman/gitlab-runner-platform/autoscaler/internal/gitlab"
	"github.com/sethbergman/gitlab-runner-platform/autoscaler/internal/metrics"
)

func TestNewSequenceReplaysValues(t *testing.T) {
	s, err := newSequence(" 3, 0 ,7 ")
	if err != nil {
		t.Fatal(err)
	}
	var got []int
	for i := 0; i < 5; i++ {
		v, err := s.PendingJobs(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, v)
	}
	if fmt.Sprint(got) != "[3 0 7 3 0]" {
		t.Errorf("sequence replayed %v", got)
	}
}

func TestNewSequenceRejectsBadSpecs(t *testing.T) {
	for _, bad := range []string{"", " , ", "1,x", "1,-2"} {
		if _, err := newSequence(bad); err == nil {
			t.Errorf("newSequence(%q) accepted", bad)
		}
	}
}

func TestSplitList(t *testing.T) {
	if got := splitList(" a, ,b ,, c "); strings.Join(got, "|") != "a|b|c" {
		t.Errorf("splitList = %q", got)
	}
	if got := splitList(""); len(got) != 0 {
		t.Errorf("splitList(\"\") = %q", got)
	}
}

func TestRoutes(t *testing.T) {
	rec := metrics.New()
	srv := httptest.NewServer(routes(rec, time.Minute))
	defer srv.Close()
	get := func(path string) (*http.Response, string) {
		t.Helper()
		resp, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return resp, string(body)
	}

	if resp, body := get("/healthz"); resp.StatusCode != http.StatusOK || body != "ok\n" {
		t.Errorf("/healthz: %d %q", resp.StatusCode, body)
	}
	if resp, _ := get("/readyz"); resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("/readyz before any reconcile: %d, want 503", resp.StatusCode)
	}
	rec.Observe(0, 0, 0, false, 0, time.Now().Add(-4*time.Minute))
	if resp, _ := get("/readyz"); resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("/readyz with a stale reconcile: %d, want 503", resp.StatusCode)
	}
	rec.Observe(0, 0, 0, false, 0, time.Now())
	if resp, body := get("/readyz"); resp.StatusCode != http.StatusOK || body != "ready\n" {
		t.Errorf("/readyz after a fresh reconcile: %d %q", resp.StatusCode, body)
	}
	resp, body := get("/metrics")
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, "warmpool_reconciles_total 2\n") {
		t.Errorf("/metrics: %d\n%s", resp.StatusCode, body)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/plain; version=0.0.4") {
		t.Errorf("/metrics Content-Type = %q", ct)
	}
}

func TestNewSourceGitLab(t *testing.T) {
	tokenFile := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tokenFile, []byte("glpat-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	src, err := newSource(config{
		source:      "gitlab",
		gitlabURL:   "https://gitlab.example.com",
		projects:    "1, group/app",
		runnerTags:  "linux,docker",
		runUntagged: true,
		tokenFile:   tokenFile,
	})
	if err != nil {
		t.Fatal(err)
	}
	c, ok := src.(*gitlab.Client)
	if !ok {
		t.Fatalf("source is %T, want *gitlab.Client", src)
	}
	if c.Token != "glpat-secret" {
		t.Errorf("token %q not trimmed", c.Token)
	}
	if fmt.Sprint(c.Projects) != "[1 group/app]" || fmt.Sprint(c.RunnerTags) != "[linux docker]" || !c.RunUntagged {
		t.Errorf("client = %+v", c)
	}
}

func TestNewSourceStaticAndErrors(t *testing.T) {
	src, err := newSource(config{source: "static", staticSequence: "1,2"})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := src.(*sequenceSource); !ok {
		t.Errorf("source is %T, want *sequenceSource", src)
	}
	for name, cfg := range map[string]config{
		"unknown source":          {source: "kafka"},
		"gitlab without url":      {source: "gitlab", projects: "1"},
		"gitlab without projects": {source: "gitlab", gitlabURL: "https://gitlab.example.com"},
		"gitlab token unreadable": {source: "gitlab", gitlabURL: "https://gitlab.example.com", projects: "1", tokenFile: filepath.Join(t.TempDir(), "missing")},
		"static empty":            {source: "static", staticSequence: " "},
	} {
		if _, err := newSource(cfg); err == nil {
			t.Errorf("%s: no error", name)
		}
	}
}

func TestMemoryScaler(t *testing.T) {
	var m memoryScaler
	ctx := context.Background()
	if n, err := m.GetReplicas(ctx, "ns", "deploy"); err != nil || n != 0 {
		t.Errorf("initial replicas %d, %v", n, err)
	}
	if err := m.SetReplicas(ctx, "ns", "deploy", 6); err != nil {
		t.Fatal(err)
	}
	if n, _ := m.GetReplicas(ctx, "ns", "deploy"); n != 6 {
		t.Errorf("replicas after set = %d", n)
	}
}

func TestFlagHelpersTakeDefaultsFromEnvironment(t *testing.T) {
	for k, v := range map[string]string{
		"T_STR": "from-env", "T_INT": "7", "T_BOOL": "true", "T_DUR": "90s",
		"T_BAD_INT": "seven", "T_BAD_BOOL": "maybe", "T_BAD_DUR": "soon",
	} {
		t.Setenv(k, v)
	}
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	var (
		s          string
		n, badN    int
		b, badB    bool
		d, badD    time.Duration
		unsetState string
	)
	str(fs, &s, "s", "T_STR", "default", "a string")
	str(fs, &unsetState, "u", "T_UNSET_FOR_TEST", "default", "unset in the environment")
	integer(fs, &n, "n", "T_INT", 1, "an int")
	integer(fs, &badN, "bad-n", "T_BAD_INT", 1, "an int with a bad env value")
	boolean(fs, &b, "b", "T_BOOL", false, "a bool")
	boolean(fs, &badB, "bad-b", "T_BAD_BOOL", false, "a bool with a bad env value")
	duration(fs, &d, "d", "T_DUR", time.Second, "a duration")
	duration(fs, &badD, "bad-d", "T_BAD_DUR", time.Second, "a duration with a bad env value")
	// A flag on the command line still beats the environment.
	if err := fs.Parse([]string{"--n=9"}); err != nil {
		t.Fatal(err)
	}
	if s != "from-env" || unsetState != "default" || n != 9 || badN != 1 || !b || badB || d != 90*time.Second || badD != time.Second {
		t.Errorf("s=%q u=%q n=%d badN=%d b=%v badB=%v d=%v badD=%v", s, unsetState, n, badN, b, badB, d, badD)
	}
	if usage := fs.Lookup("s").Usage; !strings.HasSuffix(usage, "($T_STR)") {
		t.Errorf("usage %q does not name the environment variable", usage)
	}
}

func TestNewLoggerLevels(t *testing.T) {
	ctx := context.Background()
	if !newLogger("debug", io.Discard).Enabled(ctx, slog.LevelDebug) {
		t.Error("debug logger does not enable debug")
	}
	l := newLogger("nonsense", io.Discard)
	if l.Enabled(ctx, slog.LevelDebug) || !l.Enabled(ctx, slog.LevelInfo) {
		t.Error("unknown level should fall back to info")
	}
}

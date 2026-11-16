package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestParseFlagsDefaultsEnvironmentAndArgs(t *testing.T) {
	t.Setenv("MAX_REPLICAS", "12")
	t.Setenv("INTERVAL", "3s")
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	cfg, err := parseFlags(fs, []string{"--source=static", "--interval=250ms", "--dry-run"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.namespace != "gitlab-runner-system" || cfg.deployment != "runner-warm-pool" || cfg.schedule != "Mon-Fri 07:00-19:00" || cfg.listen != ":8080" {
		t.Errorf("defaults: %+v", cfg)
	}
	if cfg.max != 12 {
		t.Errorf("max = %d, want 12 from MAX_REPLICAS", cfg.max)
	}
	if cfg.interval != 250*time.Millisecond {
		t.Errorf("interval = %s, want the flag to beat INTERVAL", cfg.interval)
	}
	if cfg.source != "static" || !cfg.dryRun {
		t.Errorf("source=%q dryRun=%v", cfg.source, cfg.dryRun)
	}
}

func TestParseFlagsErrors(t *testing.T) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if _, err := parseFlags(fs, []string{"--no-such-flag"}); err == nil {
		t.Error("unknown flag accepted")
	}
	fs = flag.NewFlagSet("test", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if _, err := parseFlags(fs, []string{"-h"}); !errors.Is(err, flag.ErrHelp) {
		t.Errorf("-h: %v, want flag.ErrHelp", err)
	}
}

func TestRunRejectsBadConfiguration(t *testing.T) {
	// Outside a cluster, which is where tests run, the real scaler cannot be built.
	t.Setenv("KUBERNETES_SERVICE_HOST", "")
	for name, tc := range map[string]struct {
		args []string
		want string
	}{
		"unknown flag":      {[]string{"--no-such-flag"}, "no-such-flag"},
		"zero interval":     {[]string{"--dry-run", "--source=static", "--interval=0"}, "interval"},
		"bad timezone":      {[]string{"--dry-run", "--source=static", "--timezone=Mars/Olympus"}, "timezone"},
		"bad schedule":      {[]string{"--dry-run", "--source=static", "--schedule=whenever"}, "schedule"},
		"minimum above max": {[]string{"--dry-run", "--source=static", "--min-business=5", "--max=4"}, "exceed max"},
		"unknown source":    {[]string{"--dry-run", "--source=kafka"}, "unknown --source"},
		"not in a cluster":  {[]string{"--source=static"}, "--dry-run"},
	} {
		err := run(context.Background(), tc.args, io.Discard)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want one mentioning %q", name, err, tc.want)
		}
	}
}

func TestRunHelpExitsClean(t *testing.T) {
	if err := run(context.Background(), []string{"-h"}, io.Discard); err != nil {
		t.Errorf("-h: %v, want nil", err)
	}
}

// lockedBuffer lets the test read logs while run is still writing them.
type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

func freeAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().String()
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func get(url string) (int, string) {
	resp, err := http.Get(url)
	if err != nil {
		return 0, err.Error()
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(body)
}

func TestRunServesAndReconcilesUntilCancelled(t *testing.T) {
	addr := freeAddr(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var logs lockedBuffer
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, []string{
			"--dry-run", "--source=static", "--static-sequence=4,0",
			"--schedule=never", "--interval=20ms", "--listen=" + addr, "--log-level=debug",
		}, &logs)
	}()
	base := "http://" + addr

	waitFor(t, "/healthz", func() bool { code, _ := get(base + "/healthz"); return code == http.StatusOK })
	waitFor(t, "/readyz after a reconcile", func() bool { code, _ := get(base + "/readyz"); return code == http.StatusOK })

	// Off-hours: the burst of 4 scales the pool to 4, and the stabilization
	// window then holds it there when the queue reads 0.
	waitFor(t, "a second reconcile", func() bool {
		_, body := get(base + "/metrics")
		return strings.Contains(body, "warmpool_reconciles_total 2")
	})
	if _, body := get(base + "/metrics"); !strings.Contains(body, "warmpool_current_replicas 4\n") {
		t.Errorf("/metrics:\n%s", body)
	}
	if !strings.Contains(logs.String(), `"msg":"resized warm pool"`) || !strings.Contains(logs.String(), `"msg":"starting"`) {
		t.Errorf("logs:\n%s", logs.String())
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("run returned %v after cancel, want nil", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("run did not return after cancel")
	}
	if code, _ := get(base + "/healthz"); code != 0 {
		t.Errorf("/healthz still answers %d after shutdown", code)
	}
}

func TestRunFailsWhenTheListenerDoes(t *testing.T) {
	taken, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	done := make(chan error, 1)
	go func() {
		done <- run(context.Background(), []string{
			"--dry-run", "--source=static", "--interval=10ms", "--listen=" + taken.Addr().String(),
		}, io.Discard)
	}()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "http server") {
			t.Errorf("err = %v, want the listen failure", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("run kept going with no listener")
	}
}

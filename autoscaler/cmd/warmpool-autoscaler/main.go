// Command warmpool-autoscaler keeps a pool of low-priority placeholder pods
// sized to the GitLab CI queue, so job pods land on nodes that are already
// running instead of waiting for new ones to boot.
//
// Configuration comes from flags, each of which can also be set through the
// environment variable shown in its help text.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	_ "time/tzdata" // --timezone works on minimal images without zoneinfo

	"github.com/sethbergman/gitlab-runner-platform/autoscaler/internal/controller"
	"github.com/sethbergman/gitlab-runner-platform/autoscaler/internal/gitlab"
	"github.com/sethbergman/gitlab-runner-platform/autoscaler/internal/kube"
	"github.com/sethbergman/gitlab-runner-platform/autoscaler/internal/metrics"
	"github.com/sethbergman/gitlab-runner-platform/autoscaler/internal/policy"
)

var version = "dev"

type config struct {
	source         string
	staticSequence string
	gitlabURL      string
	tokenFile      string
	projects       string
	runnerTags     string
	runUntagged    bool

	namespace  string
	deployment string
	dryRun     bool

	jobsPerReplica int
	headroom       int
	minBusiness    int
	minOffHours    int
	max            int
	schedule       string
	timezone       string
	stabilization  time.Duration
	interval       time.Duration

	listen   string
	logLevel string
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run() error {
	cfg := parseFlags()
	log := newLogger(cfg.logLevel)

	loc, err := time.LoadLocation(cfg.timezone)
	if err != nil {
		return fmt.Errorf("timezone: %w", err)
	}
	sched, err := policy.ParseSchedule(cfg.schedule, loc)
	if err != nil {
		return err
	}
	pol := policy.Config{
		JobsPerReplica: cfg.jobsPerReplica,
		Headroom:       cfg.headroom,
		MinBusiness:    cfg.minBusiness,
		MinOffHours:    cfg.minOffHours,
		Max:            cfg.max,
	}
	if err := pol.Validate(); err != nil {
		return err
	}

	source, err := newSource(cfg)
	if err != nil {
		return err
	}
	var scaler controller.Scaler = &memoryScaler{}
	if !cfg.dryRun {
		if scaler, err = kube.InCluster(); err != nil {
			return fmt.Errorf("%w (use --dry-run to run outside a cluster)", err)
		}
	}

	rec := metrics.New()
	rec.SetMax(pol.Max)
	ctrl := &controller.Controller{
		Source:     source,
		Scaler:     scaler,
		Policy:     pol,
		Schedule:   sched,
		Stabilizer: policy.NewStabilizer(cfg.stabilization),
		Namespace:  cfg.namespace,
		Deployment: cfg.deployment,
		Metrics:    rec,
		Log:        log,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	srv := &http.Server{
		Addr:              cfg.listen,
		Handler:           routes(rec, cfg.interval),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("http server", "err", err)
			stop()
		}
	}()

	log.Info("starting", "version", version, "source", cfg.source, "dry_run", cfg.dryRun,
		"target", cfg.namespace+"/"+cfg.deployment, "interval", cfg.interval, "schedule", cfg.schedule)
	ctrl.Run(ctx, cfg.interval)

	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return srv.Shutdown(shutdown)
}

func routes(rec *metrics.Recorder, interval time.Duration) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/metrics", rec.Handler())
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		// Live if the loop is still turning; one success is not required, so
		// a GitLab outage does not crash-loop the pod.
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		last := rec.LastSuccess()
		if last.IsZero() || time.Since(last) > 3*interval {
			http.Error(w, "no recent successful reconcile", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte("ready\n"))
	})
	return mux
}

func newSource(cfg config) (controller.QueueSource, error) {
	switch cfg.source {
	case "gitlab":
		if cfg.gitlabURL == "" || cfg.projects == "" {
			return nil, errors.New("gitlab source needs --gitlab-url and --projects")
		}
		token, err := os.ReadFile(cfg.tokenFile)
		if err != nil {
			return nil, fmt.Errorf("read GitLab token: %w", err)
		}
		return &gitlab.Client{
			BaseURL:     cfg.gitlabURL,
			Token:       strings.TrimSpace(string(token)),
			Projects:    splitList(cfg.projects),
			RunnerTags:  splitList(cfg.runnerTags),
			RunUntagged: cfg.runUntagged,
		}, nil
	case "static":
		return newSequence(cfg.staticSequence)
	default:
		return nil, fmt.Errorf("unknown --source %q (want gitlab or static)", cfg.source)
	}
}

// sequenceSource replays a fixed list of queue depths, one per reconcile. It
// exists for demos and local testing (`make demo`).
type sequenceSource struct {
	mu     sync.Mutex
	values []int
	i      int
}

func newSequence(spec string) (*sequenceSource, error) {
	var vals []int
	for _, f := range splitList(spec) {
		n, err := strconv.Atoi(f)
		if err != nil || n < 0 {
			return nil, fmt.Errorf("--static-sequence: bad value %q", f)
		}
		vals = append(vals, n)
	}
	if len(vals) == 0 {
		return nil, errors.New("--static-sequence is empty")
	}
	return &sequenceSource{values: vals}, nil
}

func (s *sequenceSource) PendingJobs(context.Context) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v := s.values[s.i%len(s.values)]
	s.i++
	return v, nil
}

// memoryScaler stands in for the Kubernetes API in --dry-run mode.
type memoryScaler struct{ replicas int }

func (m *memoryScaler) GetReplicas(context.Context, string, string) (int, error) {
	return m.replicas, nil
}

func (m *memoryScaler) SetReplicas(_ context.Context, _, _ string, n int) error {
	m.replicas = n
	return nil
}

func parseFlags() config {
	var c config
	fs := flag.CommandLine
	str(fs, &c.source, "source", "QUEUE_SOURCE", "gitlab", "queue signal: gitlab or static")
	str(fs, &c.staticSequence, "static-sequence", "STATIC_SEQUENCE", "0,4,12,30,30,8,0,0,0", "comma-separated queue depths replayed by --source=static")
	str(fs, &c.gitlabURL, "gitlab-url", "GITLAB_URL", "", "GitLab base URL")
	str(fs, &c.tokenFile, "gitlab-token-file", "GITLAB_TOKEN_FILE", "/var/run/secrets/gitlab/token", "file holding a read_api token")
	str(fs, &c.projects, "projects", "GITLAB_PROJECTS", "", "comma-separated project IDs or paths to watch")
	str(fs, &c.runnerTags, "runner-tags", "RUNNER_TAGS", "", "comma-separated tags of the runners this pool serves")
	boolean(fs, &c.runUntagged, "run-untagged", "RUN_UNTAGGED", false, "count untagged jobs")
	str(fs, &c.namespace, "namespace", "WARM_POOL_NAMESPACE", "gitlab-runner-system", "namespace of the warm-pool Deployment")
	str(fs, &c.deployment, "deployment", "WARM_POOL_DEPLOYMENT", "runner-warm-pool", "name of the warm-pool Deployment")
	boolean(fs, &c.dryRun, "dry-run", "DRY_RUN", false, "log decisions without calling the Kubernetes API")
	integer(fs, &c.jobsPerReplica, "jobs-per-replica", "JOBS_PER_REPLICA", 1, "pending jobs absorbed by one warm replica")
	integer(fs, &c.headroom, "headroom", "HEADROOM", 2, "extra replicas during business hours")
	integer(fs, &c.minBusiness, "min-business", "MIN_BUSINESS", 2, "floor during business hours")
	integer(fs, &c.minOffHours, "min-off-hours", "MIN_OFF_HOURS", 0, "floor outside business hours")
	integer(fs, &c.max, "max", "MAX_REPLICAS", 40, "ceiling, to bound spend")
	str(fs, &c.schedule, "schedule", "BUSINESS_HOURS", "Mon-Fri 07:00-19:00", `business hours, "always" or "never"`)
	str(fs, &c.timezone, "timezone", "TZ_NAME", "UTC", "IANA time zone for --schedule")
	duration(fs, &c.stabilization, "scale-down-stabilization", "SCALE_DOWN_STABILIZATION", 10*time.Minute, "hold the highest recommendation this long before scaling down")
	duration(fs, &c.interval, "interval", "INTERVAL", 15*time.Second, "reconcile interval")
	str(fs, &c.listen, "listen", "LISTEN_ADDR", ":8080", "address for /metrics, /healthz and /readyz")
	str(fs, &c.logLevel, "log-level", "LOG_LEVEL", "info", "debug, info, warn or error")
	flag.Parse()
	return c
}

func str(fs *flag.FlagSet, p *string, name, env, def, usage string) {
	if v, ok := os.LookupEnv(env); ok {
		def = v
	}
	fs.StringVar(p, name, def, usage+" ($"+env+")")
}

func integer(fs *flag.FlagSet, p *int, name, env string, def int, usage string) {
	if v, ok := os.LookupEnv(env); ok {
		if n, err := strconv.Atoi(v); err == nil {
			def = n
		}
	}
	fs.IntVar(p, name, def, usage+" ($"+env+")")
}

func boolean(fs *flag.FlagSet, p *bool, name, env string, def bool, usage string) {
	if v, ok := os.LookupEnv(env); ok {
		if b, err := strconv.ParseBool(v); err == nil {
			def = b
		}
	}
	fs.BoolVar(p, name, def, usage+" ($"+env+")")
}

func duration(fs *flag.FlagSet, p *time.Duration, name, env string, def time.Duration, usage string) {
	if v, ok := os.LookupEnv(env); ok {
		if d, err := time.ParseDuration(v); err == nil {
			def = d
		}
	}
	fs.DurationVar(p, name, def, usage+" ($"+env+")")
}

func splitList(s string) []string {
	var out []string
	for _, f := range strings.Split(s, ",") {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}

func newLogger(level string) *slog.Logger {
	var l slog.Level
	if err := l.UnmarshalText([]byte(level)); err != nil {
		l = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: l}))
}

package gitlab

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMatches(t *testing.T) {
	runner := []string{"docker", "linux", "large"}
	cases := []struct {
		job         []string
		runUntagged bool
		want        bool
	}{
		{[]string{"docker"}, false, true},
		{[]string{"docker", "large"}, false, true},
		{[]string{"docker", "gpu"}, false, false}, // runner lacks gpu
		{nil, false, false},                       // untagged, not allowed
		{nil, true, true},                         // untagged, allowed
	}
	for _, c := range cases {
		if got := Matches(c.job, runner, c.runUntagged); got != c.want {
			t.Errorf("Matches(%v, untagged=%v) = %v, want %v", c.job, c.runUntagged, got, c.want)
		}
	}
}

func TestPendingJobsPaginatesFiltersAndAuthenticates(t *testing.T) {
	var gotPaths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("PRIVATE-TOKEN") != "secret" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.URL.Query().Get("scope[]") != "pending" {
			http.Error(w, "missing scope", http.StatusBadRequest)
			return
		}
		gotPaths = append(gotPaths, r.URL.EscapedPath())
		page := r.URL.Query().Get("page")
		var jobs []job
		switch {
		case strings.Contains(r.URL.EscapedPath(), "/projects/42/") && page == "1":
			jobs = []job{{1, []string{"docker"}}, {2, []string{"gpu"}}}
			w.Header().Set("X-Next-Page", "2")
		case strings.Contains(r.URL.EscapedPath(), "/projects/42/") && page == "2":
			jobs = []job{{3, []string{"docker", "linux"}}}
		default:
			jobs = []job{{4, nil}, {5, []string{"linux"}}}
		}
		_ = json.NewEncoder(w).Encode(jobs)
	}))
	defer srv.Close()

	c := &Client{
		BaseURL:    srv.URL,
		Token:      "secret",
		Projects:   []string{"42", "platform/api"},
		RunnerTags: []string{"docker", "linux"},
	}
	got, err := c.PendingJobs(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	// project 42: jobs 1 and 3 match, 2 needs gpu. platform/api: job 5 matches,
	// job 4 is untagged and run_untagged is off.
	if got != 3 {
		t.Fatalf("PendingJobs = %d, want 3", got)
	}
	wantPath := "/api/v4/projects/platform%2Fapi/jobs"
	found := false
	for _, p := range gotPaths {
		if p == wantPath {
			found = true
		}
	}
	if !found {
		t.Fatalf("project path not URL-encoded; requests: %v", gotPaths)
	}
}

func TestPendingJobsSurfacesAPIErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"message":"403 Forbidden"}`, http.StatusForbidden)
	}))
	defer srv.Close()

	c := &Client{BaseURL: srv.URL, Token: "glpat-do-not-log", Projects: []string{"1"}}
	_, err := c.PendingJobs(context.Background())
	if err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("err = %v, want a 403 error", err)
	}
	if strings.Contains(fmt.Sprint(err), "glpat-do-not-log") {
		t.Fatal("token leaked into error")
	}
}

func TestPaginationOnlyMovesForward(t *testing.T) {
	var pages []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		pages = append(pages, r.URL.Query().Get("page"))
		w.Header().Set("X-Next-Page", map[string]string{"1": "+3", "3": "2"}[r.URL.Query().Get("page")])
		_ = json.NewEncoder(w).Encode([]job{{1, nil}})
	}))
	defer srv.Close()

	c := &Client{BaseURL: srv.URL, Projects: []string{"1"}, RunUntagged: true}
	got, err := c.PendingJobs(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	// Page 1 points on to "+3", read as page 3, which points back to 2: stop.
	if strings.Join(pages, ",") != "1,3" || got != 2 {
		t.Fatalf("pages %q, PendingJobs = %d; want pages 1,3 and 2 jobs", pages, got)
	}
}

func TestPendingJobsRequiresProjects(t *testing.T) {
	if _, err := (&Client{}).PendingJobs(context.Background()); err == nil {
		t.Fatal("want error with no projects")
	}
}

func TestMaxPagesBoundsRunawayPagination(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("X-Next-Page", fmt.Sprint(calls+1)) // there is always another page
		_ = json.NewEncoder(w).Encode([]job{{int64(calls), nil}})
	}))
	defer srv.Close()

	c := &Client{BaseURL: srv.URL, Projects: []string{"1"}, RunUntagged: true, MaxPages: 3}
	got, err := c.PendingJobs(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if calls != 3 || got != 3 {
		t.Fatalf("calls=%d got=%d, want 3 and 3", calls, got)
	}
}

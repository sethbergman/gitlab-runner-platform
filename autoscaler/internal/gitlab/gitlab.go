// Package gitlab counts pending CI jobs that a runner fleet could pick up.
//
// It uses the documented REST endpoint GET /projects/:id/jobs?scope[]=pending
// and applies GitLab's own tag-matching rule: a runner can take a job only if
// every tag on the job is also on the runner, and it takes untagged jobs only
// when run_untagged is enabled.
package gitlab

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Client is a minimal, read-only GitLab API client.
type Client struct {
	BaseURL string // e.g. https://gitlab.example.com
	Token   string // needs read_api scope; never logged
	HTTP    *http.Client

	// Scope filter: which jobs this fleet could run.
	Projects    []string // numeric IDs or URL-encoded paths ("group/app")
	RunnerTags  []string
	RunUntagged bool

	// MaxPages bounds pagination per project (100 jobs per page).
	MaxPages int
}

type job struct {
	ID      int64    `json:"id"`
	TagList []string `json:"tag_list"`
}

// PendingJobs returns the number of pending jobs, across all configured
// projects, that match this fleet's tags.
func (c *Client) PendingJobs(ctx context.Context) (int, error) {
	if len(c.Projects) == 0 {
		return 0, errors.New("gitlab: no projects configured")
	}
	total := 0
	for _, p := range c.Projects {
		n, err := c.pendingForProject(ctx, p)
		if err != nil {
			return 0, err
		}
		total += n
	}
	return total, nil
}

func (c *Client) pendingForProject(ctx context.Context, project string) (int, error) {
	maxPages := c.MaxPages
	if maxPages <= 0 {
		maxPages = 10
	}
	count := 0
	for page, i := 1, 0; i < maxPages; i++ {
		jobs, next, err := c.fetchPage(ctx, project, page)
		if err != nil {
			return 0, err
		}
		for _, j := range jobs {
			if Matches(j.TagList, c.RunnerTags, c.RunUntagged) {
				count++
			}
		}
		// Follow X-Next-Page only forward. A server that points back at a
		// page already read would otherwise have its jobs counted again, and
		// the warm pool sized for jobs that do not exist.
		if next <= page {
			break
		}
		page = next
	}
	return count, nil
}

// fetchPage returns one page of pending jobs and the X-Next-Page number, or 0
// when the header is absent or not a number.
func (c *Client) fetchPage(ctx context.Context, project string, page int) ([]job, int, error) {
	u, err := url.Parse(strings.TrimRight(c.BaseURL, "/"))
	if err != nil {
		return nil, 0, fmt.Errorf("gitlab: base url: %w", err)
	}
	// Projects may be numeric IDs or full paths; paths must be URL-encoded.
	u = u.JoinPath("api", "v4", "projects")
	u.RawPath = u.Path + "/" + url.PathEscape(project) + "/jobs"
	u.Path = u.Path + "/" + project + "/jobs"
	q := url.Values{}
	q.Add("scope[]", "pending")
	q.Set("per_page", "100")
	q.Set("page", strconv.Itoa(page))
	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("PRIVATE-TOKEN", c.Token)
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("gitlab: project %s: %w", project, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, 0, fmt.Errorf("gitlab: project %s: %s: %s", project, resp.Status, strings.TrimSpace(string(body)))
	}
	var jobs []job
	if err := json.NewDecoder(resp.Body).Decode(&jobs); err != nil {
		return nil, 0, fmt.Errorf("gitlab: project %s: decode: %w", project, err)
	}
	next, err := strconv.Atoi(resp.Header.Get("X-Next-Page"))
	if err != nil {
		next = 0
	}
	return jobs, next, nil
}

func (c *Client) httpClient() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{Timeout: 15 * time.Second}
}

// Matches reports whether a runner with runnerTags can pick up a job with
// jobTags, following GitLab's rule.
func Matches(jobTags, runnerTags []string, runUntagged bool) bool {
	if len(jobTags) == 0 {
		return runUntagged
	}
	have := make(map[string]struct{}, len(runnerTags))
	for _, t := range runnerTags {
		have[t] = struct{}{}
	}
	for _, t := range jobTags {
		if _, ok := have[t]; !ok {
			return false
		}
	}
	return true
}

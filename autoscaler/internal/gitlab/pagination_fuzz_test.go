package gitlab

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// FuzzPagination serves the same body on every page and, on the i-th request,
// the i-th comma-separated X-Next-Page value (none once they run out). The
// client must ask only for canonical page numbers, each later than the last,
// so that no page is counted twice, stay within MaxPages, and count exactly
// the matching jobs on every page it read.
func FuzzPagination(f *testing.F) {
	f.Add([]byte(`[{"id":1,"tag_list":["docker"]},{"id":2,"tag_list":[]}]`), "2,3,")
	f.Add([]byte(`[{"id":1,"tag_list":["docker"]}]`), "1")         // points back at itself
	f.Add([]byte(`[{"id":1,"tag_list":["gpu"]}]`), "3,2,4")        // goes backwards
	f.Add([]byte(`[{"id":1,"tag_list":["docker"]}]`), "+2,003,-1") // signs and leading zeros
	f.Add([]byte(`[{"id":1}]`), "2,9223372036854775808")           // out of range
	f.Add([]byte(`[]`), "2,3,4,5,6,7")                             // runs past MaxPages
	f.Add([]byte(`not json`), "2")
	f.Add([]byte(`null`), "")

	f.Fuzz(func(t *testing.T, body []byte, nexts string) {
		headers := strings.Split(nexts, ",")
		var pages []string
		c := &Client{
			BaseURL:     "https://gitlab.example.com",
			Projects:    []string{"1"},
			RunnerTags:  []string{"docker"},
			RunUntagged: true,
			MaxPages:    5,
			HTTP: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				i := len(pages)
				pages = append(pages, r.URL.Query().Get("page"))
				h := http.Header{}
				if i < len(headers) {
					h.Set("X-Next-Page", headers[i])
				}
				return &http.Response{StatusCode: http.StatusOK, Header: h, Body: io.NopCloser(bytes.NewReader(body)), Request: r}, nil
			})},
		}
		got, err := c.PendingJobs(context.Background())

		if len(pages) == 0 || len(pages) > c.MaxPages {
			t.Fatalf("%d requests, want 1 to %d", len(pages), c.MaxPages)
		}
		prev := 0
		for _, p := range pages {
			n, perr := strconv.Atoi(p)
			if perr != nil || strconv.Itoa(n) != p || n <= prev {
				t.Fatalf("requested pages %q for X-Next-Page values %q", pages, headers)
			}
			prev = n
		}

		var jobs []job
		if jerr := json.NewDecoder(bytes.NewReader(body)).Decode(&jobs); jerr != nil {
			if err == nil {
				t.Fatalf("body %q does not decode, yet PendingJobs returned %d and no error", body, got)
			}
			return
		}
		if err != nil {
			t.Fatalf("PendingJobs: %v", err)
		}
		per := 0
		for _, j := range jobs {
			if Matches(j.TagList, c.RunnerTags, c.RunUntagged) {
				per++
			}
		}
		if got != per*len(pages) {
			t.Fatalf("PendingJobs = %d over pages %q, want %d", got, pages, per*len(pages))
		}
	})
}

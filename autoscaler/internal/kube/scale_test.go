package kube

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGetAndSetReplicas(t *testing.T) {
	replicas := 3
	var patchBody, patchType, auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/apis/apps/v1/namespaces/ci-system/deployments/warm-pool/scale" {
			http.NotFound(w, r)
			return
		}
		auth = r.Header.Get("Authorization")
		switch r.Method {
		case http.MethodGet:
			_, _ = io.WriteString(w, `{"kind":"Scale","spec":{"replicas":3}}`)
		case http.MethodPatch:
			b, _ := io.ReadAll(r.Body)
			patchBody, patchType = string(b), r.Header.Get("Content-Type")
			replicas = 7
			_, _ = io.WriteString(w, `{"spec":{"replicas":7}}`)
		}
	}))
	defer srv.Close()

	tokenFile := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tokenFile, []byte("abc123\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := &Scaler{APIServer: srv.URL, TokenFile: tokenFile}
	ctx := context.Background()

	got, err := s.GetReplicas(ctx, "ci-system", "warm-pool")
	if err != nil || got != 3 {
		t.Fatalf("GetReplicas = %d, %v; want 3", got, err)
	}
	if auth != "Bearer abc123" {
		t.Fatalf("Authorization = %q", auth)
	}
	if err := s.SetReplicas(ctx, "ci-system", "warm-pool", 7); err != nil {
		t.Fatal(err)
	}
	if patchType != "application/merge-patch+json" || patchBody != `{"spec":{"replicas":7}}` {
		t.Fatalf("patch = %q (%s)", patchBody, patchType)
	}
	if replicas != 7 {
		t.Fatal("server never saw the patch")
	}
}

func TestTokenIsReReadForRotation(t *testing.T) {
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.Header.Get("Authorization"))
		_, _ = io.WriteString(w, `{"spec":{"replicas":1}}`)
	}))
	defer srv.Close()

	tokenFile := filepath.Join(t.TempDir(), "token")
	s := &Scaler{APIServer: srv.URL, TokenFile: tokenFile}
	for _, tok := range []string{"first", "second"} {
		if err := os.WriteFile(tokenFile, []byte(tok), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := s.GetReplicas(context.Background(), "ns", "d"); err != nil {
			t.Fatal(err)
		}
	}
	if seen[0] != "Bearer first" || seen[1] != "Bearer second" {
		t.Fatalf("tokens not refreshed: %v", seen)
	}
}

func TestErrorsIncludeStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `deployments.apps "warm-pool" is forbidden`, http.StatusForbidden)
	}))
	defer srv.Close()

	s := &Scaler{APIServer: srv.URL}
	err := s.SetReplicas(context.Background(), "ns", "warm-pool", 2)
	if err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("err = %v", err)
	}
	if err := s.SetReplicas(context.Background(), "ns", "warm-pool", -1); err == nil {
		t.Fatal("negative replicas accepted")
	}
}

func TestInClusterOutsideCluster(t *testing.T) {
	t.Setenv("KUBERNETES_SERVICE_HOST", "")
	if _, err := InCluster(); err == nil {
		t.Fatal("want error outside a cluster")
	}
}

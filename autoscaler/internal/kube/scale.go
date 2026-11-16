// Package kube reads and sets a Deployment's replica count through the
// scale subresource, using only the standard library.
//
// Avoiding client-go keeps the binary small and the dependency surface at
// zero; the autoscaler needs exactly two API calls, and its RBAC grants only
// get/patch on deployments/scale for one named Deployment.
package kube

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

const saDir = "/var/run/secrets/kubernetes.io/serviceaccount"

// Scaler talks to the Kubernetes API server.
type Scaler struct {
	APIServer string // https://host:port
	// TokenFile is re-read on every request because projected
	// service-account tokens rotate.
	TokenFile string
	HTTP      *http.Client
}

// InCluster builds a Scaler from the pod's service account.
func InCluster() (*Scaler, error) {
	host, port := os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")
	if host == "" || port == "" {
		return nil, errors.New("kube: not running in a cluster (KUBERNETES_SERVICE_HOST/PORT unset)")
	}
	ca, err := os.ReadFile(saDir + "/ca.crt")
	if err != nil {
		return nil, fmt.Errorf("kube: read CA: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, errors.New("kube: no certificates in ca.crt")
	}
	return &Scaler{
		APIServer: "https://" + net.JoinHostPort(host, port),
		TokenFile: saDir + "/token",
		HTTP: &http.Client{
			Timeout: 10 * time.Second,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
			},
		},
	}, nil
}

type scale struct {
	Spec struct {
		Replicas int `json:"replicas"`
	} `json:"spec"`
}

func (s *Scaler) path(namespace, name string) string {
	return fmt.Sprintf("%s/apis/apps/v1/namespaces/%s/deployments/%s/scale",
		strings.TrimRight(s.APIServer, "/"), namespace, name)
}

// GetReplicas returns spec.replicas of the Deployment.
func (s *Scaler) GetReplicas(ctx context.Context, namespace, name string) (int, error) {
	var out scale
	if err := s.do(ctx, http.MethodGet, s.path(namespace, name), "", nil, &out); err != nil {
		return 0, err
	}
	return out.Spec.Replicas, nil
}

// SetReplicas patches spec.replicas of the Deployment.
func (s *Scaler) SetReplicas(ctx context.Context, namespace, name string, replicas int) error {
	if replicas < 0 {
		return fmt.Errorf("kube: refusing negative replicas %d", replicas)
	}
	body := fmt.Sprintf(`{"spec":{"replicas":%d}}`, replicas)
	return s.do(ctx, http.MethodPatch, s.path(namespace, name),
		"application/merge-patch+json", []byte(body), nil)
}

func (s *Scaler) do(ctx context.Context, method, url, contentType string, body []byte, out any) error {
	req, err := http.NewRequestWithContext(ctx, method, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	req.Header.Set("Accept", "application/json")
	if s.TokenFile != "" {
		tok, err := os.ReadFile(s.TokenFile)
		if err != nil {
			return fmt.Errorf("kube: read token: %w", err)
		}
		req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(tok)))
	}

	client := s.HTTP
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("kube: %s %s: %w", method, req.URL.Path, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("kube: %s %s: %s: %s", method, req.URL.Path, resp.Status, strings.TrimSpace(string(msg)))
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

.PHONY: help test demo build fmt validate tf-validate manifests rules

help: ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

test: ## go vet + race-checked unit tests
	cd autoscaler && go vet ./... && go test -race ./...

demo: ## Run the autoscaler against a replayed queue, no cluster needed
	cd autoscaler && go run ./cmd/warmpool-autoscaler \
		--source=static --dry-run --schedule=never \
		--interval=1s --scale-down-stabilization=3s --listen=127.0.0.1:8080

build: ## Build the container image locally
	docker build -t warmpool-autoscaler:dev autoscaler

fmt: ## Format Go and Terraform
	cd autoscaler && gofmt -w .
	terraform fmt -recursive terraform

validate: tf-validate manifests rules ## Everything CI checks except Go

tf-validate:
	terraform fmt -check -recursive terraform
	for d in terraform/modules/runner-fleet terraform/examples/eks; do \
		terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate; \
	done

manifests:
	kubectl kustomize deploy/autoscaler | kubeconform -strict -summary -

rules:
	promtool check rules observability/prometheus-rules.yaml

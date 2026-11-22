// CI's Go tools, pinned here (with their dependencies by hash in go.sum)
// so that Dependabot keeps them current. Run one with
// `go -C .github/tools tool <name>`.
module ci-tools

go 1.26.0

tool golang.org/x/vuln/cmd/govulncheck

require (
	golang.org/x/mod v0.43.0 // indirect
	golang.org/x/sync v0.25.0 // indirect
	golang.org/x/sys v0.50.0 // indirect
	golang.org/x/telemetry v0.0.0-20261116191925-e77a43154acb // indirect
	golang.org/x/tools v0.53.0 // indirect
	golang.org/x/vuln v1.10.0 // indirect
)

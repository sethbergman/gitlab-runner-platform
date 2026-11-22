# syntax=docker/dockerfile:1.7
# Static, dependency-free binary on a distroless non-root base.
#
# The build stage runs on the builder's own platform and cross-compiles for
# the target, so an amd64 runner produces the arm64 image without emulation;
# the final stage only copies the binary, so it needs none either. Both base
# images are pinned by digest; Dependabot moves the digest along with the tag.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS build
WORKDIR /src
COPY go.mod ./
COPY . .
ARG VERSION=dev TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
      go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/warmpool-autoscaler ./cmd/warmpool-autoscaler

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
#checkov:skip=CKV_DOCKER_2:Health is checked by the Kubernetes liveness probe on /healthz; distroless has no shell or curl
COPY --from=build /out/warmpool-autoscaler /warmpool-autoscaler
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/warmpool-autoscaler"]

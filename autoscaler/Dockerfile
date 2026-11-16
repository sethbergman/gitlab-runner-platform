# syntax=docker/dockerfile:1.7
# Static, dependency-free binary on a distroless non-root base.
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/warmpool-autoscaler ./cmd/warmpool-autoscaler

FROM gcr.io/distroless/static-debian12:nonroot
#checkov:skip=CKV_DOCKER_2:Health is checked by the Kubernetes liveness probe on /healthz; distroless has no shell or curl
COPY --from=build /out/warmpool-autoscaler /warmpool-autoscaler
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/warmpool-autoscaler"]

# syntax=docker/dockerfile:1
# Multi-stage build -> single static binary on distroless (nonroot).
# Built and referenced by chapters as: bookstore/operator:dev
# Same pattern as examples/bookstore/app/catalog/Dockerfile.

FROM golang:1.26-alpine AS build
WORKDIR /src

# Cache module downloads separately from source for faster rebuilds.
COPY go.mod go.sum* ./
RUN go mod download

COPY cmd/ cmd/
COPY api/ api/
COPY internal/ internal/
# CGO disabled => fully static binary that runs on distroless-static.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/manager ./cmd

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=build /out/manager /manager
# 65532 is the "nonroot" UID/GID in distroless images (matches the restricted
# securityContext the manager Deployment sets — config/manager/manager.yaml).
USER 65532:65532
EXPOSE 8081 9443
ENTRYPOINT ["/manager"]

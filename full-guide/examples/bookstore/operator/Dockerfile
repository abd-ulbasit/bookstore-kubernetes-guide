# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# Multi-stage build -> single static binary on distroless (nonroot).
# Built and referenced by chapters as: bookstore/operator:dev
# Same pattern as examples/bookstore/app/catalog/Dockerfile.

FROM golang:1.26.10-alpine@sha256:a2012b4a1d1f9f7e9f44e0d39b805a901e856b1dd80b4e6ee4338db547050308 AS build
WORKDIR /src

# Cache module downloads separately from source for faster rebuilds.
COPY go.mod go.sum* ./
RUN go mod download

COPY cmd/ cmd/
COPY api/ api/
COPY internal/ internal/
# CGO disabled => fully static binary that runs on distroless-static.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/manager ./cmd

FROM gcr.io/distroless/static:nonroot@sha256:18f4cc26c9ffa7f20a359298be7deadac5c607c8e03a02b8119f1a5fc2f82c99
WORKDIR /
COPY --from=build /out/manager /manager
# 65532 is the "nonroot" UID/GID in distroless images (matches the restricted
# securityContext the manager Deployment sets — config/manager/manager.yaml).
USER 65532:65532
EXPOSE 8081 9443
ENTRYPOINT ["/manager"]

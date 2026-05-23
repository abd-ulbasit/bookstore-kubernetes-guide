# syntax=docker/dockerfile:1
# Multi-stage build → single static binary on distroless (nonroot).
# Built and referenced as: bookstore/catalog:dev
#
# Layer hygiene:
#   - go.mod + go.sum copied alone first so `go mod download` only
#     re-runs when deps change (not on every source edit).
#   - Build with CGO_ENABLED=0 so the result is fully static and runs on
#     distroless (which has no libc).
#   - -trimpath + -ldflags="-s -w" strip the absolute build path and the
#     debug symbols → smaller binary, no leakage of /Users/... paths.

FROM golang:1.25-alpine AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/service .

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build /out/service /app/service
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app/service"]

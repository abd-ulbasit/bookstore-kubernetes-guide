# syntax=docker/dockerfile:1
# Multi-stage build -> single static binary on distroless (nonroot).
# Built and referenced as: bookstore-platform/search:dev

# Base images pinned by digest; tags in the comments.
# golang:1.26.10-alpine
FROM golang:1.26.10-alpine@sha256:a2012b4a1d1f9f7e9f44e0d39b805a901e856b1dd80b4e6ee4338db547050308 AS build
WORKDIR /src

COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/search .

# gcr.io/distroless/static:nonroot
FROM gcr.io/distroless/static:nonroot@sha256:18f4cc26c9ffa7f20a359298be7deadac5c607c8e03a02b8119f1a5fc2f82c99
WORKDIR /
COPY --from=build /out/search /search
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/search"]

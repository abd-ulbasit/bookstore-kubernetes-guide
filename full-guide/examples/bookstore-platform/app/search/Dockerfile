# syntax=docker/dockerfile:1
# Multi-stage build -> single static binary on distroless (nonroot).
# Built and referenced as: bookstore-platform/search:dev

FROM golang:1.26-alpine AS build
WORKDIR /src

COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/search .

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=build /out/search /search
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/search"]

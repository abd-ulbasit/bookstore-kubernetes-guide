# syntax=docker/dockerfile:1
# Multi-stage build -> single static binary on distroless (nonroot).
# Built and referenced as: bookstore/payments-worker:dev
# No EXPOSE: this is a background worker with no customer-facing HTTP port
# (the /healthz endpoint binds on PORT but is cluster-internal only).

FROM golang:1.22-alpine AS build
WORKDIR /src

COPY go.mod ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/service .

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build /out/service /app/service
USER 65532:65532
ENTRYPOINT ["/app/service"]

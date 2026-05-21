# syntax=docker/dockerfile:1
# Multi-stage build -> single static binary on distroless (nonroot).
# Built and referenced by chapters as: bookstore/payments-worker:dev

FROM golang:1.26-alpine AS build
WORKDIR /src

COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/payments-worker .

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=build /out/payments-worker /payments-worker
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/payments-worker"]

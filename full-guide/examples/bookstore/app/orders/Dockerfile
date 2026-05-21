# syntax=docker/dockerfile:1
# Multi-stage build -> single static binary on distroless (nonroot).
# Built and referenced by chapters as: bookstore/orders:dev

FROM golang:1.26-alpine AS build
WORKDIR /src

COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/orders .

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=build /out/orders /orders
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/orders"]

# INSECURE ON PURPOSE: a scanner fixture, never a template. Every line that
# looks careless here is planted so hadolint, Dockle, Trivy, Syft and Grype
# have something to report. Build it only inside the pipeline's own tests.
FROM golang:1.26.10-alpine AS build
WORKDIR /src
COPY go.mod go.sum main.go ./
RUN CGO_ENABLED=0 go build -o /out/vulnerable .

# An end-of-life base, so the image scanners find known CVEs in it.
FROM alpine:3.12
# hadolint DL3018 (unpinned package) and DL3020 (ADD where COPY is meant).
RUN apk add --no-cache curl
ADD config.env /app/config.env
# Dockle CIS-DI-0010: a credential-looking name in the environment.
ENV API_TOKEN=fixture-not-a-real-token
COPY --from=build /out/vulnerable /vulnerable
# hadolint DL3002 and Dockle CIS-DI-0001: the image runs as root.
USER root
EXPOSE 8080
ENTRYPOINT ["/vulnerable"]

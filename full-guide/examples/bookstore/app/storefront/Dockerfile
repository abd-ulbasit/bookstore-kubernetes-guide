# syntax=docker/dockerfile:1
# Static storefront on nginx, running as the unprivileged "nginx" user (UID 101).
# Built and referenced by chapters as: bookstore/storefront:dev

# nginx stable 1.30.6 on Alpine. The tag is the line to follow, the digest is the
# content that was scanned; Dependabot moves both together.
FROM nginx:1.30-alpine@sha256:0e52bd054126cdc040b1276c0af347aeb02a41b9cfe305d6094767ac30e97949

# The storefront never calls curl, and the base image ships it with libcurl,
# which bring their own CVE stream. Nothing else depends on either: remove them.
RUN apk del --no-cache curl libcurl

# Replace the default config with our unprivileged one (listens on :8080,
# all temp paths under /tmp so it works with readOnlyRootFilesystem in k8s).
COPY nginx.conf /etc/nginx/nginx.conf
COPY index.html /usr/share/nginx/html/index.html

# Pre-create the writable temp dirs and hand ownership to the nginx user so the
# container can run with USER nonroot and a read-only root filesystem.
RUN mkdir -p /tmp/client_body /tmp/proxy /tmp/fastcgi /tmp/uwsgi /tmp/scgi \
    && chown -R nginx:nginx /tmp/client_body /tmp/proxy /tmp/fastcgi /tmp/uwsgi /tmp/scgi /usr/share/nginx/html \
    && chmod -R 0770 /tmp/client_body /tmp/proxy /tmp/fastcgi /tmp/uwsgi /tmp/scgi

# UID 101 == the "nginx" user in the official alpine image.
USER 101
EXPOSE 8080
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]

# syntax=docker/dockerfile:1
# Static storefront on nginx, running as the unprivileged "nginx" user (UID 101).
# Built and referenced by chapters as: bookstore/storefront:dev

FROM nginx:1.27-alpine

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

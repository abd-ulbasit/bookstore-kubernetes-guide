# `edge/` — Gateway API + Coraza WAF + per-tenant rate limiting

The v2 edge story (ch.13.07). Three jobs at the edge: terminate TLS +
route, defend (WAF + rate limit), authenticate (JWT verify — ch.13.04
already shipped this part).

## Files

- `gateway.yaml` — Gateway API `GatewayClass` + `Gateway` + four
  `HTTPRoute`s (public static, API v2, API v1 fallback, Stripe webhook).
  Replaces the legacy Ingress shape v1 used.
- `coraza-envoy-filter.yaml` — Coraza WAF as an Envoy WASM filter loaded
  on the ingress-gateway Pod. OWASP CRS v4 rules. Blocks SQL-injection,
  XSS, command-injection, path-traversal.
- `rate-limit-envoy-filter.yaml` — Envoy local rate limiter EnvoyFilter
  + a small Lua filter that extracts the `tenant` claim from
  `x-jwt-payload` and keys the rate-limit bucket per tenant.

## Apply order

```sh
# 1. Gateway API CRDs (one-shot; before Istio is fine too).
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

# 2. Istio with Gateway API support (default since 1.21; ch.13.04 §1).
#    (already installed if ch.13.04 ran)

# 3. The Gateway + Routes
kubectl apply -f examples/bookstore-platform/edge/gateway.yaml

# 4. WAF + rate limit
kubectl apply -f examples/bookstore-platform/edge/coraza-envoy-filter.yaml
kubectl apply -f examples/bookstore-platform/edge/rate-limit-envoy-filter.yaml

# 5. Confirm
kubectl -n istio-system get envoyfilter
kubectl -n bookstore-platform get gateway,httproute
```

## Test the WAF

```sh
# Healthy request — 200
curl -sk https://localhost:8443/static/index.html

# SQL injection attempt — 403 (Coraza CRS rule 942100)
curl -sk "https://localhost:8443/api/v2/search?q=1' OR '1'='1"

# XSS attempt — 403 (CRS rule 941100)
curl -sk "https://localhost:8443/api/v2/search?q=<script>alert(1)</script>"

# Rate limit — 100 requests in 10s; the 101st returns 429
for i in $(seq 1 105); do
  curl -sk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $JWT" \
    https://localhost:8443/api/v2/search?q=test
done | sort | uniq -c
# 100 200
#   5 429
```

## Honest notes

- **Coraza WASM pinning.** The chapter pins the Coraza release tag in
  the EnvoyFilter; production pins the OCI digest
  (`oci://...@sha256:<DIGEST>`) so a re-tag of the upstream image can't
  silently change the WAF behaviour. The chapter walks both.
- **CRS tuning.** CRS v4 is noisy. Out-of-the-box rule 942100 fires on
  any URL with a single quote — many legitimate book titles trip it.
  The chapter's Production notes flag the tuning loop (start in
  `DetectionOnly` mode, watch the audit log, whitelist false positives,
  flip to `On`).
- **Lua-vs-WASM for the JWT claim extraction.** Lua is the kind-friendly
  path. Production usually uses a custom WASM filter for performance
  + base64-decode correctness — the chapter calls this out.

## Cross-references

- Ch.13.07 — the chapter that authors this stack.
- `../auth/` (ch.13.04) — the JWT validation that this edge complements.
- `../crossplane/composition-bookstoretenant.yaml` (ch.13.02) — provides
  the per-tenant `quota` field that production wires to the rate-limit
  descriptors (this file ships a static 100-per-10s default).

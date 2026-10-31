# `edge/` — Gateway API + Coraza WAF + per-tenant rate limiting

The v2 edge story (ch.13.07). Three jobs at the edge: terminate TLS +
route, defend (WAF + rate limit), authenticate (JWT verify, ch.13.04).

## Files

- `edge-ca.yaml`: the edge CA (a cert-manager self-signed root and a CA
  issuer, both namespaced in `bookstore-platform`) and the gateway's serving
  certificate. Replaces a literal Secret.
- `jwt-policies.yaml`: copies of the ch.13.04 RequestAuthentication and the
  two AuthorizationPolicies, selecting the Gateway API pods. Also copies the
  verified `tenant` claim to `x-tenant`.
- `gateway.yaml`: Gateway API `GatewayClass` + `Gateway`, an HTTP-to-HTTPS
  redirect, three `HTTPRoute`s (public static, API, Stripe webhook) and the
  `ReferenceGrant`s their backends need.
- `coraza-wasmplugin.yaml`: Coraza WAF as an Istio `WasmPlugin` (digest
  pinned), phase AUTHN, OWASP CRS v4. Blocks SQL injection, XSS,
  command injection and path traversal.
- `rate-limit-envoy-filter.yaml`: the Envoy local rate limiter, a Lua filter
  that drops a client-sent `x-tenant`, the token buckets, and the route
  action that keys them on the verified tenant.

## Apply order

Run it after ch.13.04 (Istio and the RequestAuthentication).

```sh
# 1. Gateway API CRDs (ch.13.07 step 1).
# 2. cert-manager with its namespace labelled restricted, then the edge CA
#    and the Gateway (ch.13.07 step 2).
kubectl apply -f examples/bookstore-platform/edge/edge-ca.yaml
kubectl apply -f examples/bookstore-platform/edge/gateway.yaml
kubectl apply -f examples/bookstore-platform/edge/jwt-policies.yaml

# 3. WAF and rate limit
kubectl apply -f examples/bookstore-platform/edge/coraza-wasmplugin.yaml
kubectl apply -f examples/bookstore-platform/edge/rate-limit-envoy-filter.yaml

# 4. Confirm
kubectl -n bookstore-platform get gateway,httproute,wasmplugin,envoyfilter
```

## Test the edge

Export the CA once, then reach the gateway through a port-forward:

```sh
kubectl -n bookstore-platform get secret edge-ca -o jsonpath='{.data.ca\.crt}' \
  | base64 -d > edge-ca.crt
kubectl -n bookstore-platform port-forward svc/bookstore-platform-edge-istio 8443:443 >/dev/null 2>&1 &

curl -s --cacert edge-ca.crt -o /dev/null -w "%{http_code}\n" \
  https://localhost:8443/static/index.html
```

Chapter 13.07 steps 5 and 6 walk the WAF and rate-limit checks.

## Honest notes

- **Gateway pods.** A Gateway provisions its own pods, so the WAF, the rate
  limit and (in ch.13.04) the JWT and AuthZ policies select them with
  `gateway.networking.k8s.io/gateway-name`, not `istio: ingressgateway`.
- **Tenant header.** The rate limit trusts `x-tenant` only when ch.13.04's
  RequestAuthentication sets it from a verified token.
- **CRS tuning.** CRS v4 is noisy. Start in `DetectionOnly`, review the
  audit log, add path-scoped exclusions, then set `On` (ch.13.07 step 7).

## Cross-references

- Ch.13.07 — the chapter that authors this stack.
- `../auth/` (ch.13.04) — the JWT validation that this edge complements.
- `../crossplane/composition-bookstoretenant.yaml` (ch.13.02): the tenant
  identity these buckets key on. The quota it sets is not yet wired here;
  the buckets are the static 100-per-10s starting point.

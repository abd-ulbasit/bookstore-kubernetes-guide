# `auth/` — Keycloak OIDC + Istio JWT + IRSA wiring

The two identity planes from 13.04, expressed as YAML:

- **Humans -> Keycloak OIDC** at the Istio Gateway (verified by
  `request-authentication.yaml`, enforced by `authorization-policy.yaml`).
- **Workloads -> IAM via SA federation** (illustrated by
  `sample-serviceaccount-irsa.yaml`; real wiring at Part 10 ch.03).

| File | Kind(s) | Purpose |
|------|---------|---------|
| `request-authentication.yaml` | `RequestAuthentication` × 1 | Verify the Keycloak JWT at the gateway: issuer, JWKS over HTTPS, audiences. |
| `authorization-policy.yaml` | `AuthorizationPolicy` × 2 | Allow public static paths; require a verified principal and a `tenant` claim for `/api/*`. Anything else is denied by default. |
| `keycloak-realm-import.cm.yaml` | `ConfigMap` | Realm definition imported on first start: clients, audience and tenant mappers, groups, token lifetimes. No literal secrets. |
| `sample-serviceaccount-irsa.yaml` | `ServiceAccount` | EKS-IRSA annotation pattern (GKE/AKS equivalents commented). |

## Apply order

```sh
# Prereqs: Istio installed (13.04 step 1). Argo CD installed. cert-manager
# installed for TLS at the gateway. The keycloak namespace is labelled and
# holds the three Secrets from 13.04 step 2.

kubectl apply -f examples/bookstore-platform/argocd/application-keycloak.yaml
# Argo CD syncs the chart and mounts the realm-import ConfigMap below.
kubectl apply -f examples/bookstore-platform/auth/keycloak-realm-import.cm.yaml

kubectl apply -f examples/bookstore-platform/auth/request-authentication.yaml
kubectl apply -f examples/bookstore-platform/auth/authorization-policy.yaml

# The IRSA-annotated SA is illustrative on kind; on EKS it actually wires:
kubectl apply -f examples/bookstore-platform/auth/sample-serviceaccount-irsa.yaml
```

## CRD-intrinsic dry-runs

`RequestAuthentication` and `AuthorizationPolicy` are Istio CRDs; both fail
client dry-run with `no matches for kind` before Istio is installed. The
`ConfigMap` and `ServiceAccount` are core Kubernetes kinds and dry-run
cleanly without anything else installed.

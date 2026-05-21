# `auth/` — Keycloak OIDC + Istio JWT + IRSA wiring

The two identity planes from 13.04, expressed as YAML:

- **Humans -> Keycloak OIDC** at the Istio Gateway (verified by
  `request-authentication.yaml`, enforced by `authorization-policy.yaml`).
- **Workloads -> IAM via SA federation** (illustrated by
  `sample-serviceaccount-irsa.yaml`; real wiring at Part 10 ch.03).

| File | Kind(s) | Purpose |
|------|---------|---------|
| `request-authentication.yaml` | `RequestAuthentication` × 2 | Verify Keycloak JWT at gateway + per-workload (Istio). |
| `authorization-policy.yaml` | `AuthorizationPolicy` × 3 | Enforce "JWT required for `/api/*`", allow public static, deny everything else. |
| `keycloak-realm-import.cm.yaml` | `ConfigMap` | Realm definition mounted into Keycloak on first boot (clients, roles, groups, tenant claim mapper). |
| `sample-serviceaccount-irsa.yaml` | `ServiceAccount` | EKS-IRSA annotation pattern (GKE/AKS equivalents commented). |

## Apply order

```sh
# Prereqs: Istio installed (Part 11 ch.04; pinned-Helm). Keycloak installed
# via Bitnami chart (pinned). cert-manager installed for TLS at the gateway.

kubectl apply -f examples/bookstore-platform/auth/keycloak-realm-import.cm.yaml
# Then helm install / upgrade Keycloak with the realm-import ConfigMap mounted
# (see 13.04 Hands-on for the helm values block).

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

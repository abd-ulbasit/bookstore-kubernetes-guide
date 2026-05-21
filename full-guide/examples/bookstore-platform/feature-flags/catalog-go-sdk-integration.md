# Integrating a feature-flag SDK in a Bookstore Go service

> How the catalog Go service consumes a feature-flag SDK to evaluate
> the `catalog_v2_search_engine` and `kill_switch_checkout` flags.
> Demonstrates both **Flagsmith** (self-hosted; default) and
> **LaunchDarkly** (SaaS; alternative). The OpenFeature SDK shape
> abstracts the provider so the Bookstore can swap without code
> changes — the explicit goal of OpenFeature.

## Decision: Flagsmith vs LaunchDarkly vs Unleash

| Concern                | Flagsmith (self-hosted) | LaunchDarkly (SaaS)     | Unleash (self-hosted)  |
|------------------------|-------------------------|-------------------------|------------------------|
| **Data residency**     | yes (your DB)           | no (LD's data plane)    | yes                    |
| **Cost at 10K MAU**    | ~$0 (compute only)      | ~$300/mo                | ~$0                    |
| **Cost at 1M+ MAU**    | ~$0                     | ~$3000+/mo              | ~$0                    |
| **SDK maturity**       | good (Go, JS, Python)   | excellent (every lang)  | good (Go, Java, Node)  |
| **Setup time**         | 30 min (Helm)           | 5 min (signup)          | 30 min (Helm)          |
| **Operational load**   | Postgres + 2 Pods       | none                    | Postgres + 2 Pods      |
| **Audit log**          | yes (built-in)          | yes (built-in)          | yes (built-in)         |
| **Compliance**         | self-managed            | LD's SOC2 + GDPR        | self-managed           |

**Bookstore Platform default**: **Flagsmith** (data residency for EU
tenants; cost at platform scale). **LaunchDarkly fallback**: when
the team explicitly chooses SaaS to skip operational load (e.g. an
early-stage team that should not host Postgres for a flag service).
**Unleash**: an alternative to Flagsmith with the same trade-offs;
team preference.

The SDK shape below is **OpenFeature** (CNCF; vendor-neutral). The
provider is configurable; the Go code never imports a vendor SDK
directly.

## The integration shape

The catalog service uses a **port-and-adapter** layout (the v2 hexagonal
shape; see [Part 13 ch.01](../../../13-grand-capstone-bookstore-platform/01-bookstore-2-from-toy-to-platform.md)).
Feature-flag access is a **driven port** — the catalog code calls an
interface; the adapter wires it to OpenFeature + a provider.

```text
catalog/
├── internal/
│   ├── ports/
│   │   └── flags.go               <- the FlagsPort interface (driven port)
│   ├── adapters/
│   │   └── flags/
│   │       ├── openfeature.go    <- OpenFeature client (vendor-neutral)
│   │       ├── flagsmith.go      <- Flagsmith provider wiring
│   │       └── launchdarkly.go   <- LaunchDarkly provider wiring (alt)
│   └── search/
│       └── service.go             <- consumer; depends on FlagsPort
└── main.go                        <- wires Flagsmith or LD by env var
```

## The port — `internal/ports/flags.go`

```go
package ports

import "context"

// FlagsPort is the driven port the catalog service depends on to
// read feature-flag values. No vendor types leak past this boundary.
type FlagsPort interface {
    // Bool returns the bool value for `key`, or `defaultValue` if the
    // flag cannot be evaluated (provider down, flag missing, etc.).
    Bool(ctx context.Context, key string, defaultValue bool, eval EvalContext) bool

    // String returns the string value (for multivariate flags).
    String(ctx context.Context, key string, defaultValue string, eval EvalContext) string

    // Int returns the int value (for config-shaped flags).
    Int(ctx context.Context, key string, defaultValue int, eval EvalContext) int
}

// EvalContext carries the targeting attributes — tenant, user, region.
// The provider uses these for segment matching + percentage splits.
type EvalContext struct {
    TenantID  string
    UserID    string
    Email     string
    Region    string
    Tier      string  // enterprise | standard
    Extras    map[string]string
}
```

## The OpenFeature adapter — `internal/adapters/flags/openfeature.go`

```go
package flags

import (
    "context"

    "github.com/open-feature/go-sdk/openfeature"
    "go.uber.org/zap"

    "github.com/bookstore-platform/catalog/internal/ports"
)

// OpenFeatureFlags is a ports.FlagsPort backed by the OpenFeature SDK.
// The actual provider (Flagsmith / LaunchDarkly / Unleash) is registered
// at startup by main.go.
type OpenFeatureFlags struct {
    client *openfeature.Client
    log    *zap.SugaredLogger
}

func NewOpenFeatureFlags(clientName string, log *zap.SugaredLogger) *OpenFeatureFlags {
    return &OpenFeatureFlags{
        client: openfeature.NewClient(clientName),
        log:    log,
    }
}

func (f *OpenFeatureFlags) Bool(ctx context.Context, key string, defaultValue bool, eval ports.EvalContext) bool {
    val, err := f.client.BooleanValue(ctx, key, defaultValue, toEvalCtx(eval))
    if err != nil {
        // Provider failed; emit metric + log and return the safe default.
        f.log.Warnw("flag eval failed",
            "flag", key, "err", err,
            "tenant", eval.TenantID, "user", eval.UserID,
        )
        return defaultValue
    }
    return val
}

func (f *OpenFeatureFlags) String(ctx context.Context, key string, defaultValue string, eval ports.EvalContext) string {
    val, err := f.client.StringValue(ctx, key, defaultValue, toEvalCtx(eval))
    if err != nil {
        f.log.Warnw("flag eval failed (string)", "flag", key, "err", err)
        return defaultValue
    }
    return val
}

func (f *OpenFeatureFlags) Int(ctx context.Context, key string, defaultValue int, eval ports.EvalContext) int {
    val, err := f.client.IntValue(ctx, key, int64(defaultValue), toEvalCtx(eval))
    if err != nil {
        f.log.Warnw("flag eval failed (int)", "flag", key, "err", err)
        return defaultValue
    }
    return int(val)
}

func toEvalCtx(eval ports.EvalContext) openfeature.EvaluationContext {
    return openfeature.NewEvaluationContext(
        eval.UserID,
        map[string]interface{}{
            "tenant": eval.TenantID,
            "email":  eval.Email,
            "region": eval.Region,
            "tier":   eval.Tier,
        },
    )
}
```

## Wiring Flagsmith — `internal/adapters/flags/flagsmith.go`

```go
package flags

import (
    "context"

    flagsmith "github.com/Flagsmith/flagsmith-go-client/v3"
    "github.com/open-feature/go-sdk-contrib/providers/flagsmith/pkg"
    "github.com/open-feature/go-sdk/openfeature"
)

// RegisterFlagsmith wires the Flagsmith SDK into OpenFeature as the
// default provider. Call once at startup, BEFORE any FlagsPort access.
//
// `apiURL` is the in-cluster Flagsmith API ("http://flagsmith-api.flagsmith.svc:8000/api/v1/"),
// `envKey` is the per-environment server-side key (an ExternalSecret
// from the Vault `kv/data/feature-flags/flagsmith` path; see ch.15.05).
func RegisterFlagsmith(ctx context.Context, apiURL, envKey string) error {
    client := flagsmith.NewClient(envKey,
        flagsmith.WithBaseURL(apiURL),
        flagsmith.WithLocalEvaluation(ctx),  // pull flags every 60s for
                                              // low-latency in-process eval
        flagsmith.WithEnvironmentRefreshInterval(60),
    )
    provider := flagsmithProvider.NewProvider(client)
    return openfeature.SetProvider(provider)
}
```

## Wiring LaunchDarkly — `internal/adapters/flags/launchdarkly.go`

```go
package flags

import (
    ld "github.com/launchdarkly/go-server-sdk/v7"
    ldProvider "github.com/open-feature/go-sdk-contrib/providers/launchdarkly/pkg"
    "github.com/open-feature/go-sdk/openfeature"
)

// RegisterLaunchDarkly wires the LaunchDarkly SDK as the OpenFeature
// provider. Used in environments where the team chose the SaaS path.
//
// `sdkKey` is the per-environment server-side key from LaunchDarkly;
// stored in Vault `kv/data/feature-flags/launchdarkly`.
func RegisterLaunchDarkly(sdkKey string) error {
    client, err := ld.MakeClient(sdkKey, 5)
    if err != nil {
        return err
    }
    provider := ldProvider.NewProvider(client)
    return openfeature.SetProvider(provider)
}
```

## Wiring in main.go

```go
func main() {
    ctx := context.Background()
    log := ...

    provider := os.Getenv("FEATURE_FLAG_PROVIDER")  // "flagsmith" | "launchdarkly"
    switch provider {
    case "flagsmith":
        if err := flags.RegisterFlagsmith(ctx,
            os.Getenv("FLAGSMITH_API_URL"),
            os.Getenv("FLAGSMITH_ENV_KEY"),
        ); err != nil {
            log.Fatalw("flagsmith registration failed", "err", err)
        }
    case "launchdarkly":
        if err := flags.RegisterLaunchDarkly(os.Getenv("LD_SDK_KEY")); err != nil {
            log.Fatalw("launchdarkly registration failed", "err", err)
        }
    default:
        log.Warnw("FEATURE_FLAG_PROVIDER not set; flags default-only", "provider", provider)
        // FlagsPort still works — every Bool/String/Int call returns the
        // hardcoded default. Safe for kind / local dev.
    }

    flagsPort := flags.NewOpenFeatureFlags("catalog", log)
    searchService := search.NewService(flagsPort, ...)
    ...
}
```

## Consuming the flag — `internal/search/service.go`

```go
func (s *Service) Search(ctx context.Context, q SearchQuery) (*SearchResult, error) {
    // Decide which engine to use based on the dark-launch flag.
    eval := ports.EvalContext{
        TenantID: q.TenantID,
        UserID:   q.UserID,
        Email:    q.Email,
        Region:   s.region,
        Tier:     q.Tier,
    }

    engine := s.flags.String(ctx, "catalog_v2_search_engine", "legacy_postgres_ilike", eval)

    switch engine {
    case "meilisearch_v1":
        return s.meilisearch.Query(ctx, q)
    case "legacy_postgres_ilike":
        return s.postgresIlike.Query(ctx, q)
    default:
        // Unknown variant -> safe fallback.
        s.log.Warnw("unknown engine variant", "engine", engine)
        return s.postgresIlike.Query(ctx, q)
    }
}

// Checkout: hit the kill switch first.
func (h *Handler) Checkout(w http.ResponseWriter, r *http.Request) {
    eval := evalContextFromRequest(r)
    enabled := h.flags.Bool(r.Context(), "kill_switch_checkout", true, eval)
    //                                                              ^^^^
    // default-safe: if the provider is DOWN, the kill switch is "on"
    // (= checkout works). The kill switch is INVERSE; flipped to false
    // means disabled.
    if !enabled {
        http.Error(w, "Checkout temporarily disabled — see status page", http.StatusServiceUnavailable)
        return
    }
    // ... normal checkout
}
```

## Safety: the default-on-failure pattern

Every flag call passes a **default**. The default is the **safe**
choice — what happens if the flag service is unreachable. For
kill-switches, the default is "feature enabled" (i.e. the kill-switch
flag is "true" = healthy). The flag flipping to "false" disables; the
flag service being DOWN means the default ("true") applies and the
service stays available.

**Anti-pattern**: defaulting kill-switches to "false" (disabled). A
Flagsmith outage then disables every kill-switched feature — the
flag-service becomes a single point of failure for the whole product.

## Local development (kind, no Flagsmith)

The catalog service must run on `kind` (no Flagsmith installed). The
SDK `WithLocalEvaluation` mode reads a static JSON file when
`FLAGSMITH_API_URL` is unset:

```sh
# .env.local for local dev
FEATURE_FLAG_PROVIDER=
# unset; FlagsPort returns the hardcoded defaults

# OR use the static-JSON fallback (Flagsmith SDK feature)
FEATURE_FLAG_PROVIDER=flagsmith
FLAGSMITH_API_URL=file:///etc/catalog/flags-local.json
FLAGSMITH_ENV_KEY=local
```

The static JSON is `sample-flag-config.json` adapted to the local
default values — checked into `examples/bookstore-platform/feature-
flags/`.

## Observability

OpenFeature emits **Hooks** the catalog wires to Prometheus:

```go
openfeature.AddHooks(
    promHook.New(prometheus.DefaultRegisterer, "catalog_flag_"),
)
// Emits:
//   catalog_flag_evaluation_count{flag="catalog_v2_search_engine", result="meilisearch_v1"}
//   catalog_flag_evaluation_duration_seconds_bucket{flag=..., le="0.01"}
//   catalog_flag_error_count{flag=..., reason="provider_down"}
```

Two SLO alerts (in `examples/bookstore-platform/observability/`):

- `FlagsmithProviderDown` (`catalog_flag_error_count > 0 for 5m`) —
  the SDK can't talk to Flagsmith; flags are running on defaults.
  **P2** by default (the defaults are safe); **P1** if a dark-launch
  is in flight (the rollout pauses).
- `FlagEvaluationLatency` (`p99 > 10ms for 5m`) — Flagsmith's local-
  evaluation mode should be sub-millisecond; > 10ms suggests a
  network issue or a bug.

## Related docs

- [`README.md`](README.md) — the feature-flags directory index.
- [`flagsmith-helm-values.yaml`](flagsmith-helm-values.yaml) — the
  Flagsmith install for the cluster.
- [`sample-flag-config.json`](sample-flag-config.json) — example
  flag configurations.
- [Part 15 ch.08 — feature flags & dark launches](../../../15-day-to-day-production-ops/08-feature-flags-and-dark-launches.md) —
  the chapter introducing this integration.
- [Part 15 ch.05 — production secrets](../../../15-day-to-day-production-ops/05-production-secrets-vault-eso.md) —
  where the Flagsmith env-key is stored.
- [Part 13 ch.01 — Bookstore v2](../../../13-grand-capstone-bookstore-platform/01-bookstore-2-from-toy-to-platform.md) —
  the hexagonal port-and-adapter shape this integration follows.

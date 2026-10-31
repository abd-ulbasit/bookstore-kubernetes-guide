# The vulnerable fixture

A tiny service that is broken on purpose. It exists so the pipeline can prove
that each scanner still catches what it is there to catch (Part 07 ch.03).

**Never deploy it, and never copy a line of it into a real service.** It runs
only inside the pipeline's own control jobs. Its fake credentials belong to no
account.

The control jobs in `.github/workflows/bookstore-pipeline-check.yml` run each
scanner through `ci/scan.sh --expect ID`. A control passes only when the
scanner flags the fixture and its report names the ID below. If a scanner goes
quiet, crashes, or renames its rules, the control fails.

| Scanner | Planted issue | Expected ID |
|---|---|---|
| Gitleaks | a token-shaped string in `config.env` | `github-pat` |
| TruffleHog | a second one, run without verification | `Github` |
| Gitleaks, TruffleHog (history) | two tokens committed and then deleted, in a throwaway repository that `../make-history.sh` builds at run time | `github-pat`, `Github` |
| Semgrep | SQL built by joining strings (`main.go`) | `bookstore-sql-string-concat` |
| gosec | the same query, and a shell fed by a request | `G202` |
| govulncheck | a reachable call into `x/text` v0.3.6 | `GO-2021-0113` |
| Trivy, dependencies | the same old `x/text` | `CVE-2021-38561` |
| hadolint | `USER root`, an unpinned package, `ADD` for a file | `DL3002` |
| Dockle | the image runs as root | `CIS-DI-0001` |
| Trivy, image | an end-of-life Alpine base | `CVE-2022-37434` |
| Grype, Trivy (SBOM) | the Syft SBOM of that image | `CVE-2021-38561` |
| Trivy, config | a privileged Pod in `deployment.json` | `KSV-0017` |
| KubeLinter | the same Pod | `privileged-container` |
| kubesec | the same Pod | `Privileged` |
| Conftest | a namespace in a Terraform plan with no `enforce` label (`policy/plan.json`) | `BK-TF-001` |
| zizmor | a PR title pasted into a shell (`bad-workflow.yml`) | `template-injection` |
| actionlint | the same line | `potentially untrusted` |
| expiry check | an exception list (`exceptions.conf`) with a lapsed date and an undated entry | `lapsed on 2020-01-01`, `no Revisit by DATE` |
| ZAP baseline | a session cookie without `HttpOnly` (and an HTML page with no security headers) | `10010` |

The manifest is JSON on purpose. The guide's own YAML gates read every `.yaml`
file under `examples/` as work to fix, and this one must stay broken.
`bad-workflow.yml` sits outside `.github/workflows/`, so GitHub never runs it.

The repo's own scans skip this directory: `.gitleaks.toml` allows the two
fake tokens by exact path and line, `security-scan.yml` skips it for Trivy and
govulncheck. Each skip is covered by a control, so none can hide a quiet
scanner.

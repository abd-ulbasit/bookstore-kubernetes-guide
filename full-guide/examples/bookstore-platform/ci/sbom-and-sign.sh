#!/usr/bin/env bash
################################################################################
# sbom-and-sign.sh — local helper for the Bookstore Platform CI image-signing
# path. Generates an SBOM with syft and signs the image keyless via cosign,
# mirroring the GitHub Actions workflow in this directory so a developer can:
#
#   - dry-run the signing flow locally before pushing to CI
#   - sign an ad-hoc image (e.g. a release-only branch, a hotfix tag)
#   - regenerate an SBOM after the image was rebuilt from cache
#
# This is NOT meant for production signing — production signing happens in
# CI, where the OIDC identity is the workflow itself (the verifiable subject
# Kyverno `verifyImages` matches on). A laptop-driven `cosign sign` uses the
# operator's interactive OIDC (typically GitHub/Google), which IS a real
# Sigstore identity but is NOT the workflow identity production verifies
# against. Part 15 ch.03 explains the distinction.
#
# USAGE:
#
#   ./sbom-and-sign.sh <SERVICE> <IMAGE_REFERENCE>
#
#   <SERVICE>          short name (catalog / orders / payments-worker)
#   <IMAGE_REFERENCE>  fully-qualified image reference; MUST be by digest
#                      (registry/repo@sha256:...). A tag is rejected.
#
# Example:
#
#   ./sbom-and-sign.sh catalog \
#     'AWS_ACCOUNT_ID.dkr.ecr.AWS_REGION.amazonaws.com/bookstore/catalog@sha256:abc...'
#
# REQUIREMENTS (preflight-checked below):
#
#   - cosign v2.x          (https://docs.sigstore.dev/cosign/installation/)
#   - syft  v1.x           (https://github.com/anchore/syft#installation)
#   - docker / podman      (for image pull only; not used for build)
#   - an OIDC-capable browser session if running this interactively (the
#     GitHub Actions OIDC flag below skips the browser when running INSIDE
#     CI; the env var COSIGN_IDENTITY_TOKEN, if set, overrides browser flow
#     entirely — handy for non-interactive shells with an OIDC token already
#     in hand)
#
# WHAT IT WRITES:
#
#   - <SERVICE>.spdx.json       — SPDX-JSON SBOM
#   - <SERVICE>.cosign.bundle   — signature bundle (cert + sig + Rekor entry)
#                                 — useful for offline verification later
#
# WHAT IT DOES NOT DO:
#
#   - Build the image. (Local builds aren't reproducible enough for signing.
#     Sign what you pushed to a registry, not what's in your local cache.)
#   - Push the image. (Same reason — push first, then sign the digest.)
################################################################################

set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 <SERVICE> <IMAGE_REFERENCE>

  <SERVICE>          one of: catalog, orders, payments-worker
  <IMAGE_REFERENCE>  registry/repo@sha256:HEX (digest required; tags rejected)

Example:
  $0 catalog 'AWS_ACCOUNT_ID.dkr.ecr.AWS_REGION.amazonaws.com/bookstore/catalog@sha256:abc...'
USAGE
}

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

SERVICE="$1"
IMAGE_REF="$2"

case "$SERVICE" in
  catalog|orders|payments-worker) ;;
  *)
    echo "ERROR: unknown service '$SERVICE'. Expected catalog | orders | payments-worker." >&2
    usage
    exit 2
    ;;
esac

# Refuse a tag. cosign will technically sign a tag-ref, but the signature
# then "covers" whatever the tag currently points at — which is exactly the
# mutability problem digests solve. Hard-fail here so the local flow can't
# silently mis-sign.
if ! echo "$IMAGE_REF" | grep -q '@sha256:[0-9a-f]\{64\}$'; then
  echo "ERROR: image reference must be a digest (registry/repo@sha256:HEX)." >&2
  echo "Refusing to sign tag-based reference: '$IMAGE_REF'" >&2
  exit 2
fi

# Preflight: tools.
require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' not found on PATH." >&2
    echo "Install: $2" >&2
    exit 3
  fi
}
require_tool cosign 'https://docs.sigstore.dev/cosign/installation/'
require_tool syft   'https://github.com/anchore/syft#installation'

COSIGN_VERSION=$(cosign version 2>/dev/null | awk '/GitVersion/ {print $2; exit}')
SYFT_VERSION=$(syft version 2>/dev/null | awk '/Version:/ {print $2; exit}')
echo "==> cosign ${COSIGN_VERSION:-unknown}, syft ${SYFT_VERSION:-unknown}"
echo "==> Service:  $SERVICE"
echo "==> Image:    $IMAGE_REF"

OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"
SBOM_FILE="${OUTPUT_DIR}/${SERVICE}.spdx.json"
BUNDLE_FILE="${OUTPUT_DIR}/${SERVICE}.cosign.bundle"

# --- 1. SBOM -----------------------------------------------------------------
echo "==> Generating SBOM with syft (SPDX JSON) -> ${SBOM_FILE}"
syft "$IMAGE_REF" -o spdx-json > "$SBOM_FILE"
echo "    SBOM size: $(wc -c < "$SBOM_FILE") bytes"

# --- 2. Sign (keyless) -------------------------------------------------------
# cosign v2 enables keyless by default when no --key is passed. The OIDC
# flow:
#   - interactive: opens a browser to the configured issuer (default
#     https://oauth2.sigstore.dev/auth, which federates to GitHub/Google/
#     Microsoft); the operator authenticates; cosign exchanges the token
#     at Fulcio for a short-lived cert.
#   - non-interactive: if COSIGN_IDENTITY_TOKEN is set, cosign uses that
#     token directly (the path GitHub Actions takes, with the workflow's
#     id-token: write JWT exported as the env var).
#
# COSIGN_YES=true silences the "are you sure you want to use the public
# Rekor instance?" prompt. Acceptable for the public Sigstore instance;
# for a private Sigstore deployment set COSIGN_FULCIO_URL / COSIGN_REKOR_URL
# instead.
echo "==> cosign sign (keyless) ..."
COSIGN_YES=true \
  cosign sign \
    --yes \
    --output-signature "${BUNDLE_FILE%.bundle}.sig" \
    --output-certificate "${BUNDLE_FILE%.bundle}.cert" \
    "$IMAGE_REF"

# --- 3. Attest SBOM ----------------------------------------------------------
echo "==> cosign attest SBOM (SPDX-JSON)"
COSIGN_YES=true \
  cosign attest \
    --yes \
    --type spdxjson \
    --predicate "$SBOM_FILE" \
    "$IMAGE_REF"

# --- 4. Verify -------------------------------------------------------------------
# Verify with a deliberately loose identity match in this local flow — the
# operator's email/issuer varies. Production verification (Kyverno's
# verifyImages rule) is tight: --certificate-identity-regexp matches the
# specific workflow ref, --certificate-oidc-issuer is locked to
# token.actions.githubusercontent.com. Part 15 ch.03 shows the production
# pattern; this is the operator-friendly local smoke test.
echo "==> Verifying signature (operator-loose; CI/Kyverno uses tight match)"
cosign verify \
  --certificate-identity-regexp '.*' \
  --certificate-oidc-issuer-regexp '.*' \
  "$IMAGE_REF" \
  | head -c 2000
echo
echo "    (full attestation chain available via 'cosign verify-attestation')"

echo "==> Done."
echo "    Signed:        $IMAGE_REF"
echo "    SBOM:          $SBOM_FILE"
echo "    Bundle pieces: ${BUNDLE_FILE%.bundle}.sig / .cert"
echo
echo "    Next: in CI, the same flow runs with the workflow's OIDC identity"
echo "    and Kyverno (Part 15 ch.03) verifies against THAT identity at"
echo "    admission. This local run is reachable from any operator's"
echo "    Sigstore identity and is NOT what production gates on."

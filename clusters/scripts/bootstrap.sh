#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_TOKEN:?missing GITHUB_TOKEN.}"
: "${OP_SERVICE_ACCOUNT_TOKEN:?missing OP_SERVICE_ACCOUNT_TOKEN.}"

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

main() {
    local start_epoch end_epoch elapsed
    local owner repository branch origin

    origin="$(resolve_origin)"
    read -r owner repository branch <<<"$origin"

    resolve_target "${1:-}" bootstrap

    start_epoch=$(date +%s)
    log "Start time: $(date -r "$start_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
    log "Target:     $env_name/$cluster"
    log "Entrypoint: $cluster_path"
    log "Kubeconfig: $cluster_kubeconfig"
    log "Repo:       $owner/$repository"
    log "Branch:     $branch"

    log "Seeding the 1Password service account token"

    vault_namespace=external-secrets-system

    kc get namespace "$vault_namespace" >/dev/null 2>&1 || \
        kc create namespace "$vault_namespace"

    kc create secret generic onepassword-token \
      --namespace="$vault_namespace" \
      --from-literal=token="$OP_SERVICE_ACCOUNT_TOKEN" \
      --dry-run=client -o yaml | kc apply -f -

    log "Creating Github repository and bootstrapping flux system"

    fx bootstrap github \
      --token-auth \
      --owner="$owner" \
      --repository="$repository" \
      --branch="$branch" \
      --path="$cluster_path" \
      --personal

    end_epoch=$(date +%s)
    elapsed=$(( end_epoch - start_epoch ))
    log "End time:   $(date -r "$end_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
    log "Elapsed:    $((elapsed / 3600))h $(((elapsed % 3600) / 60))m $((elapsed % 60))s (${elapsed}s)"
}

main "$@"

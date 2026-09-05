#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Reverse of the dependsOn chain, which spans three files: `apps` and
# `bootstrap` are declared in clusters/entrypoints/<env>/<cluster>/{main,bootstrap}.yaml,
# and everything between them in the layer-zero package under platform/.
# Children are deleted before their parent so each inventory is garbage-collected
# in order rather than cascading out of a single prune.
stages=(observability-instances observability-collectors apps observability-operators observability shims core base operators platform secrets-eso secrets-operators secrets bootstrap)

halt_reconciliation() {
    fx suspend source git flux-system
    fx suspend source git platform-foundation
    fx suspend kustomization flux-system
}

delete_stages() {
    local stage
    for stage in "${stages[@]}"; do
        if ! kc get kustomization "$stage" -n flux-system >/dev/null 2>&1; then
            log "  $stage: already gone"
            continue
        fi
        log "  $stage: deleting and waiting for its inventory to be garbage-collected"
        fx delete kustomization "$stage" --silent
        kc wait --for=delete kustomization/"$stage" -n flux-system --timeout=15m
    done
}

wipe_leftovers() {
    local lbs
    kc delete pvc --all --all-namespaces --timeout=10m

    lbs="$(kc get svc --all-namespaces \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}')"
    while read -r ns name; do
        [[ -n "${name:-}" ]] || continue
        log "  deleting LoadBalancer $ns/$name"
        kc delete svc "$name" -n "$ns" --timeout=10m
    done <<<"$lbs"
}

# terraform destroy removes the nodes running ebs-csi-controller and
# aws-cloud-controller-manager. Once they are gone nothing is left to release the
# EBS volumes or the ELB, so refuse to hand back until the cluster shows none.
assert_cloud_resources_released() {
    local deadline pvs lbs

    if ! kc version --request-timeout=30s >/dev/null 2>&1; then
        printf 'error: cannot reach the cluster, so the release of EBS volumes and the ELB cannot be confirmed\n' >&2
        return 1
    fi

    deadline=$(( $(date +%s) + 900 ))

    while :; do
        if ! pvs="$(kc get pv -o name --request-timeout=60s | grep -c . || true)"; then
            printf 'error: unable to list PersistentVolumes\n' >&2
            return 1
        fi
        if ! lbs="$(kc get svc --all-namespaces --request-timeout=60s \
            -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' \
            | grep -c . || true)"; then
            printf 'error: unable to list Services\n' >&2
            return 1
        fi

        if [[ "$pvs" == "0" && "$lbs" == "0" ]]; then
            log "  no PersistentVolumes, no LoadBalancer Services"
            return 0
        fi

        if (( $(date +%s) > deadline )); then
            printf 'error: cloud resources still present after 15m: %s PersistentVolume(s), %s LoadBalancer Service(s)\n' \
                "$pvs" "$lbs" >&2
            printf 'error: NOT safe for terraform destroy -- EBS volumes or an ELB would be orphaned\n' >&2
            kc get pv 2>&1 >&2 || true
            return 1
        fi

        log "  waiting: $pvs PersistentVolume(s), $lbs LoadBalancer Service(s) remaining"
        sleep 15
    done
}

main() {
    local start_epoch end_epoch elapsed

    resolve_target "${1:-}" destroy

    start_epoch=$(date +%s)
    log "Start time: $(date -r "$start_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
    log "Target:     $env_name/$cluster"
    log "Kubeconfig: $cluster_kubeconfig"

    log "Suspending the git source and the root kustomization so flux stops syncing"
    halt_reconciliation

    log "Deleting stage kustomizations in reverse dependency order"
    delete_stages

    log "Force-wiping any remaining PVCs and LoadBalancer Services"
    wipe_leftovers

    log "Verifying every cloud-backed resource is released"
    assert_cloud_resources_released

    end_epoch=$(date +%s)
    elapsed=$(( end_epoch - start_epoch ))
    log "End time:   $(date -r "$end_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
    log "Elapsed:    $((elapsed / 3600))h $(((elapsed % 3600) / 60))m $((elapsed % 60))s (${elapsed}s)"
    log "Safe to run terraform destroy"
}

main "$@"

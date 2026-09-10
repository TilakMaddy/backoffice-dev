#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Reverse of the dependsOn chain, which spans four files: `common`, `apps` and
# `bootstrap` are declared in clusters/entrypoints/<env>/<cluster>/{main,bootstrap}.yaml,
# `pg-backups` in clusters/apps/chain-indexer/02-postgres/backups.yaml, and everything
# between them in the layer-zero package under platform/.
# Children are deleted before their parent so each inventory is garbage-collected
# in order rather than cascading out of a single prune.
stages=(observability-instances observability-collectors pg-backups apps common observability-operators observability shims core base operators underlay secrets-eso secrets-operators secrets bootstrap)

halt_reconciliation() {
    local stage

    fx suspend source git flux-system
    fx suspend kustomization flux-system

    # Suspending the source only stops new fetches: every Kustomization keeps
    # reconciling the artifact source-controller already has on disk, so a live
    # parent puts a just-deleted child straight back and the delete waits out its
    # whole timeout for an inventory that keeps returning. The whole tree is
    # suspended here; delete_stages resumes each one immediately before deleting
    # it, because flux drops the finalizer without pruning when a Kustomization
    # is suspended -- suspended-and-deleted would leave every workload running.
    for stage in "${stages[@]}"; do
        kc get kustomization "$stage" -n flux-system >/dev/null 2>&1 || continue
        fx suspend kustomization "$stage"
    done
}

delete_stages() {
    local stage
    for stage in "${stages[@]}"; do
        if ! kc get kustomization "$stage" -n flux-system >/dev/null 2>&1; then
            log "  $stage: already gone"
            continue
        fi
        log "  $stage: deleting and waiting for its inventory to be garbage-collected"
        # Resume so the delete actually prunes; the parent stays suspended, which
        # is what keeps the delete from being undone. --wait=false because the
        # next line deletes it rather than waiting for a reconcile.
        fx resume kustomization "$stage" --wait=false
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

# Namespaces the platform and its apps create. Each is declared in a manifest, so
# deleting the stage that owns it should prune it; anything still standing at the
# end is reported rather than left silently behind.
namespaces=(platform-system chain-indexer alloy-system cert-manager-system cnpg-system envoy-gateway-system external-dns-system external-secrets-system grafana-system keel-system kyverno-system loki-system prometheus-system reloader-system tempo-system)

# Deleting the stages leaves flux itself: the controllers, the toolkit CRDs, the
# flux-system namespace and the suspended sources. Removing them is what makes the
# next bootstrap behave like one against a cluster that has never seen flux.
uninstall_flux() {
    if ! kc get namespace flux-system >/dev/null 2>&1; then
        log "  flux-system: already gone"
        return 0
    fi
    fx uninstall --silent
}

# bootstrap.sh seeds the 1Password token before flux exists, so that namespace can
# outlive the stage that would otherwise own it.
remove_bootstrap_leftovers() {
    local ns=external-secrets-system

    if ! kc get namespace "$ns" >/dev/null 2>&1; then
        log "  $ns: already gone"
        return 0
    fi

    log "  deleting leftover namespace $ns"
    kc delete namespace "$ns" --timeout=5m
}

report_remaining_namespaces() {
    local ns remaining=()

    for ns in "${namespaces[@]}" flux-system; do
        kc get namespace "$ns" >/dev/null 2>&1 && remaining+=("$ns")
    done

    if [[ ${#remaining[@]} -eq 0 ]]; then
        log "  none left, the cluster is back to what it was before bootstrap"
        return 0
    fi

    printf 'warning: %d namespace(s) still present:\n' "${#remaining[@]}" >&2
    printf '         %s\n' "${remaining[@]}" >&2
    printf '         a namespace stuck Terminating is usually a finalizer on one of its resources\n' >&2
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

    log "Uninstalling flux -- controllers, toolkit CRDs and the flux-system namespace"
    uninstall_flux

    log "Removing what bootstrap created outside flux"
    remove_bootstrap_leftovers

    log "Verifying every cloud-backed resource is released"
    assert_cloud_resources_released

    log "Checking no platform namespace survived"
    report_remaining_namespaces

    end_epoch=$(date +%s)
    elapsed=$(( end_epoch - start_epoch ))
    log "End time:   $(date -r "$end_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
    log "Elapsed:    $((elapsed / 3600))h $(((elapsed % 3600) / 60))m $((elapsed % 60))s (${elapsed}s)"
    log "Cluster is empty again. Safe to run terraform destroy, or to bootstrap it afresh"
}

main "$@"

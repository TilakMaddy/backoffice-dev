#!/usr/bin/env bash
set -euo pipefail

vault="${OP_VAULT:-MyIndexer}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

envs=(
    local
    staging
    production
)

fields=(
    cloudflare-api-token
    resend-smtp-password
    envio-token
    acme-email
    alert-email-to
    grafana-smtp-host
    grafana-smtp-user
    grafana-smtp-from-address
    grafana-admin-username
    grafana-admin-password
    chain-indexer-pg-password
    chain-indexer-pg-superuser-password
    chain-indexer-hasura-admin-secret
    pg-backup-destination
    pg-backup-region
)

# Read from `terraform output` in infra/<env> on every run, so the bucket can
# never drift from the one terraform created.
terraform_fields=(
    pg-backup-destination
    pg-backup-region
)

# Issued by a third party, or naming a person or a domain; only a human can
# supply them.
external_fields=(
    cloudflare-api-token
    resend-smtp-password
    envio-token
    acme-email
    alert-email-to
    grafana-smtp-from-address
)

main() {
    local env_name matches

    if ! op vault get "$vault" >/dev/null 2>&1; then
        printf 'error: cannot reach vault %s -- not signed in to op, or no access to it.\n' "$vault" >&2
        printf '       op must be authenticated: desktop app integration, op signin, or\n' >&2
        printf '       OP_SERVICE_ACCOUNT_TOKEN. A service account needs write access granted.\n' >&2
        exit 1
    fi

    for env_name in "${envs[@]}"; do
        resolve_terraform "$env_name"
        matches="$(count_items "$env_name")"
        case "$matches" in
            0) create "$env_name" ;;
            1) backfill "$env_name" ;;
            *)
                printf 'error: %d items titled %s in %s, refusing to guess.\n' \
                    "$matches" "$env_name" "$vault" >&2
                exit 1
                ;;
        esac
    done

    printf '\nfill in by hand, per item:\n'
    printf '    %s\n' "${external_fields[@]}"
}

count_items() {
    op item list --vault "$vault" --format=json \
        | jq --arg title "$1" '[.[] | select(.title == $title)] | length'
}

create() {
    local env_name="$1" field
    local assignments=()

    for field in "${fields[@]}"; do
        assignments+=("${field}[password]=$(value_for "$env_name" "$field")")
    done

    op item create \
        --vault "$vault" \
        --category "Secure Note" \
        --title "$env_name" \
        "${assignments[@]}" >/dev/null

    printf 'created  %s/%s with %d fields\n' "$vault" "$env_name" "${#fields[@]}"
}

backfill() {
    local env_name="$1" field
    local assignments=()

    for field in "${fields[@]}"; do
        # Terraform-backed fields are rewritten every run rather than left alone.
        # When terraform could not be read, an existing value is kept and only a
        # missing one is seeded, so the field always exists for External Secrets.
        if is_terraform_field "$field"; then
            if [[ "$tf_available" == yes ]] \
                || [[ -z "$(op read "op://$vault/$env_name/$field" 2>/dev/null)" ]]; then
                assignments+=("${field}[password]=$(value_for "$env_name" "$field")")
            fi
            continue
        fi

        op read "op://$vault/$env_name/$field" >/dev/null 2>&1 && continue
        assignments+=("${field}[password]=$(value_for "$env_name" "$field")")
    done

    if [[ ${#assignments[@]} -eq 0 ]]; then
        printf 'ok       %s/%s, all %d fields present\n' "$vault" "$env_name" "${#fields[@]}"
        return
    fi

    op item edit "$env_name" --vault "$vault" "${assignments[@]}" >/dev/null

    printf 'updated  %s/%s, wrote %d field(s)\n' "$vault" "$env_name" "${#assignments[@]}"
}

is_terraform_field() {
    local field
    for field in "${terraform_fields[@]}"; do
        [[ "$1" == "$field" ]] && return 0
    done
    return 1
}

# Sets tf_available, tf_destination and tf_region for one env. Never fatal: an
# env with no terraform (local) or unreachable state leaves whatever the vault
# already holds.
resolve_terraform() {
    local env_name="$1" dir="$repo_root/infra/$1"

    tf_available=no
    tf_destination=
    tf_region=

    [[ -f "$dir/main.tf" ]] || return 0

    # `terraform output -raw` exits 0 and prints nothing when there is no state,
    # so an empty value has to count as unreadable or the vault gets "".
    tf_destination="$(terraform -chdir="$dir" output -raw pg_backups_destination 2>/dev/null)" || true
    tf_region="$(terraform -chdir="$dir" output -raw pg_backups_region 2>/dev/null)" || true

    if [[ -z "$tf_destination" || -z "$tf_region" ]]; then
        printf 'skipped  %s/%s pg-backup-*, no terraform output in infra/%s (apply it first)\n' \
            "$vault" "$env_name" "$env_name"
        return 0
    fi

    tf_available=yes
}

value_for() {
    local env_name="$1" field="$2"

    case "$field" in
        cloudflare-api-token|resend-smtp-password|envio-token|acme-email|alert-email-to|grafana-smtp-from-address)
            printf 'REPLACE_ME-%s-%s' "$env_name" "$field"
            ;;
        grafana-smtp-host)
            printf 'smtp.resend.com:587'
            ;;
        grafana-smtp-user)
            printf 'resend'
            ;;
        grafana-admin-username)
            printf 'admin'
            ;;
        pg-backup-destination)
            if [[ "$tf_available" == yes ]]; then printf '%s' "$tf_destination"
            else printf 'REPLACE_ME-%s-%s' "$env_name" "$field"; fi
            ;;
        pg-backup-region)
            if [[ "$tf_available" == yes ]]; then printf '%s' "$tf_region"
            else printf 'REPLACE_ME-%s-%s' "$env_name" "$field"; fi
            ;;
        *)
            generate
            ;;
    esac
}

# Alphanumeric only: chain-indexer-pg-password is interpolated raw into
# HASURA_GRAPHQL_DATABASE_URL, where + / = @ : would corrupt the URI.
generate() {
    local raw
    raw="$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
    printf '%s' "${raw:0:32}"
}

main "$@"

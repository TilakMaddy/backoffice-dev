#!/usr/bin/env bash
set -euo pipefail

vault="${OP_VAULT:-OatLabs}"

envs=(
    local
    staging
    production
)

fields=(
    cloudflare-api-token
    resend-smtp-password
    envio-token
    grafana-admin-username
    grafana-admin-password
    chain-indexer-pg-password
    chain-indexer-pg-superuser-password
    chain-indexer-hasura-admin-secret
)

# Issued by a third party; only a human can supply them.
external_fields=(
    cloudflare-api-token
    resend-smtp-password
    envio-token
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
        op read "op://$vault/$env_name/$field" >/dev/null 2>&1 && continue
        assignments+=("${field}[password]=$(value_for "$env_name" "$field")")
    done

    if [[ ${#assignments[@]} -eq 0 ]]; then
        printf 'ok       %s/%s, all %d fields present\n' "$vault" "$env_name" "${#fields[@]}"
        return
    fi

    op item edit "$env_name" --vault "$vault" "${assignments[@]}" >/dev/null

    printf 'backfill %s/%s, added %d field(s)\n' "$vault" "$env_name" "${#assignments[@]}"
}

value_for() {
    local env_name="$1" field="$2"

    case "$field" in
        cloudflare-api-token|resend-smtp-password|envio-token)
            printf 'REPLACE_ME-%s-%s' "$env_name" "$field"
            ;;
        grafana-admin-username)
            printf 'admin'
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

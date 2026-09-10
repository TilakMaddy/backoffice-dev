#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Everything printed here is read from the vault, so this deliberately does not
# use resolve_target: that insists on a kubeconfig, and there is no reason to
# have fetched one just to look up a URL and a password.
target="${1-}"

# An env on its own -- "staging" -- is accepted when it holds exactly one
# cluster, which is the common case. Anything ambiguous falls through to the
# same <env>/<cluster> form the other scripts take.
if [[ -n "$target" && "$target" != */* ]]; then
    matches="$(discover_targets | awk -v e="$target" -F/ '$1 == e')"
    case "$(printf '%s' "$matches" | grep -c . || true)" in
        1) target="$matches" ;;
        0)
            printf 'error: no clusters under env %q\n' "$target" >&2
            printf 'known targets:\n' >&2
            discover_targets | sed 's/^/  /' >&2
            exit 1
            ;;
        *)
            printf 'error: env %q holds more than one cluster, name one:\n' "$target" >&2
            printf '%s\n' "$matches" | sed 's/^/  /' >&2
            exit 1
            ;;
    esac
fi

if [[ -z "$target" ]]; then
    target="$(select_target "show-details")" || true
    if [[ -z "$target" ]]; then
        printf 'usage: %s <env>[/<cluster>]\n' "$0" >&2
        exit 1
    fi
fi

env_name="${target%%/*}"
cluster="${target#*/}"
entrypoint="$entrypoints_dir/$env_name/$cluster"

if [[ ! -d "$entrypoint" ]]; then
    printf 'error: no entrypoint for %q at %s\n' "$target" "$entrypoint" >&2
    exit 1
fi

# The op:// references are read back out of the entrypoint rather than repeated
# here, so a renamed vault item only has to change in one place.
op_ref() {
    local key="$1" ref
    ref="$(awk -v k="  $1: " 'index($0, k) == 1 {print $2}' \
        "$entrypoint"/bootstrap.yaml "$entrypoint"/main.yaml 2>/dev/null | head -1)"
    if [[ -z "$ref" ]]; then
        printf 'error: %s not found in %s/{bootstrap,main}.yaml\n' "$key" "$entrypoint" >&2
        return 1
    fi
    printf 'op://%s/%s' "$vault" "$ref"
}

vault="$(awk '/^  OP_VAULT: /{print $2}' "$entrypoint"/bootstrap.yaml)"
if [[ -z "$vault" ]]; then
    printf 'error: no OP_VAULT in %s/bootstrap.yaml\n' "$entrypoint" >&2
    exit 1
fi

zone="$(op read "$(op_ref OP_VAULT_CLUSTER_ZONE)")"
grafana_user="$(op read "$(op_ref OP_VAULT_GRAFANA_ADMIN_USER)")"
grafana_pass="$(op read "$(op_ref OP_VAULT_GRAFANA_ADMIN_PASSWORD)")"
hasura_secret="$(op read "$(op_ref OP_VAULT_CHAIN_INDEXER_HASURA_ADMIN_SECRET)")"
pg_pass="$(op read "$(op_ref OP_VAULT_CHAIN_INDEXER_PG_SUPERUSER_PASSWORD)")"

pg_pass_enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$pg_pass")"
ca="$repo_root/clusters/tests/stg-root-x1.pem"

printf '%s (%s)\n\n' "$target" "$zone"

printf 'GRAFANA\n'
printf '  url:      https://grafana.%s\n' "$zone"
printf '  username: %s\n' "$grafana_user"
printf '  password: %s\n\n' "$grafana_pass"

printf 'HASURA\n'
printf '  console:  https://hasura-chain-indexer.%s/console\n' "$zone"
printf '  graphql:  https://hasura-chain-indexer.%s/v1/graphql\n' "$zone"
printf '  password: %s   (admin secret -- hasura has no usernames)\n\n' "$hasura_secret"

printf 'POSTGRES\n'
printf '  host:     postgres-chain-indexer.%s\n' "$zone"
printf '  port:     5432\n'
printf '  database: indexer-db\n'
printf '  username: postgres  (SUPERUSER -- unrestricted on every database)\n'
printf '  password: %s\n' "$pg_pass"
printf '  ssl mode: verify-full\n\n'

printf '  Import URL\n'
printf '    postgresql://postgres:%s@postgres-chain-indexer.%s:5432/indexer-db?sslmode=verify-full\n\n' \
    "$pg_pass_enc" "$zone"

printf '  SQL Shell\n'
printf '    psql "postgresql://postgres:%s@postgres-chain-indexer.%s:5432/indexer-db?sslmode=verify-full&sslrootcert=%s"\n\n' \
    "$pg_pass_enc" "$zone" "$ca"

printf 'ssl ca:     %s\n' "$ca"

# The staging ACME endpoint issues from a root nothing trusts, so every client
# needs the CA above; production certs chain to the real Let's Encrypt root.
if [[ "$(awk '/^  ACME_ENV: /{print $2}' "$entrypoint"/bootstrap.yaml)" == "staging" ]]; then
    printf 'note:       certificates chain to the Let'"'"'s Encrypt STAGING root, so browsers\n'
    printf '            warn and curl/psql need the CA above.\n'
fi

if [[ "$env_name" == "local" ]]; then
    printf 'note:       kind publishes LoadBalancer ports on 127.0.0.1, so these hostnames\n'
    printf '            are not reachable from off this machine.\n'
fi

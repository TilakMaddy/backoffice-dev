FluxCD entrypoints for various clusters.

Each `<env>/<cluster>` holds four ConfigMaps across three files, plus the flux
Kustomizations that consume them:

| file | ConfigMap | |
|---|---|---|
| `owner-vars.yaml` | `platform-owner-vars` | yours: zone, cluster id, vault name |
| | `cluster-owner-vars` | yours: indexer image |
| `bootstrap.yaml` | `platform-vars` | vault paths and platform wiring, plus the layer-zero source and Kustomization |
| `main.yaml` | `cluster-vars` | vault paths and tunables, plus the common and apps Kustomizations |

A new owner edits `owner-vars.yaml` and the `GitRepository` url and branch in
`bootstrap.yaml`. Everything else runs as-is.

The vault name is in two places that have to agree: `OP_VAULT` in
`owner-vars.yaml`, and the default in `scripts/seed-vault.sh`.

The `OP_VAULT_*` values in `platform-vars` and `cluster-vars` are addresses
inside that vault. Their field names are fixed by `scripts/seed-vault.sh`; only
the `<env>/` prefix is yours to pick.

`chain-indexer-vars`, the fourth ConfigMap the apps Kustomization substitutes
from, lives in `clusters/common`, next to the `cluster-secret-vars` ExternalSecret
that carries the Postgres backup destination and region.

Those two come from terraform, not from a file here: `just seed-vault` reads
`terraform output` in `infra/<env>` and writes them into the vault on every run,
so run it after `terraform apply`. An env with no terraform, or state it cannot
reach, is skipped with a note and keeps whatever the vault already holds.

Run it with:

    cd infra/<env> && just apply
    just seed-vault
    just bootstrap <env>/<cluster>

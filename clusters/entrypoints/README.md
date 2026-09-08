FluxCD entrypoints for various clusters.

Each `<env>/<cluster>` holds four ConfigMaps across four files, plus the flux
Kustomizations that consume them:

| file | ConfigMap | |
|---|---|---|
| `platform-owner-vars.yaml` | `platform-owner-vars` | yours: zone, cluster id, vault name |
| `cluster-owner-vars.yaml` | `cluster-owner-vars` | yours: indexer image, backup bucket |
| `bootstrap.yaml` | `platform-vars` | vault paths and platform wiring, plus the layer-zero source and Kustomization |
| `main.yaml` | `cluster-vars` | vault paths and tunables, plus the common and apps Kustomizations |

A new owner edits the two `*-owner-vars.yaml` files and the `GitRepository` url
and branch in `bootstrap.yaml`. Everything else runs as-is.

The vault name is in two places that have to agree: `OP_VAULT` in
`platform-owner-vars.yaml`, and the default in `scripts/seed-vault.sh`.

The `OP_VAULT_*` values in `platform-vars` and `cluster-vars` are addresses
inside that vault. Their field names are fixed by `scripts/seed-vault.sh`; only
the `<env>/` prefix is yours to pick.

`chain-indexer-vars`, the fourth ConfigMap the apps Kustomization substitutes
from, lives in `clusters/common`.

Run it with:

    just seed-vault
    just bootstrap <env>/<cluster>

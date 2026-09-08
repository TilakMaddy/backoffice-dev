FluxCD entrypoints for various clusters.

Each `<env>/<cluster>` holds `bootstrap.yaml` (the `platform-vars` ConfigMap +
the layer-zero source and Kustomization) and `main.yaml` (the `cluster-vars`
ConfigMap + the common and apps Kustomizations). Both ConfigMaps group their
keys the same way:

- `# yours` -- identity that has to live in git, because flux reads it before
  the vault is reachable. Domain, cluster id, image repository, backup bucket.
- `# vault` -- the 1Password vault name and the `op://<vault>/<env>/<field>`
  paths behind it. The field names are fixed by `scripts/seed-vault.sh`; only
  `OP_VAULT` and the `<env>` prefixes are yours to pick. Emails and the SMTP
  provider live here, not in git.
- `# common` -- platform wiring and tunables. Runs as-is.

Outside the ConfigMaps, a new owner also changes the `GitRepository` url and
branch in `bootstrap.yaml`. `chain-indexer-vars`, the third ConfigMap the apps
Kustomization substitutes from, lives in `clusters/common`.

Run it with:

    just seed-vault
    just bootstrap <env>/<cluster>

# Setup guide

Standing up a cluster from nothing. See the [README](README.md) for what the stack is and
what it gives you.

## Prerequisites

Install `terraform`, `aws`, `just`, `jq`, `fzf`, `kubectl`, `helm`, `flux`, `op` and
`talosctl` — on macOS:

```sh
brew install terraform awscli just jq fzf kubectl helm \
  fluxcd/tap/flux 1password-cli siderolabs/tap/talosctl
```

## Credentials

Credentials come from the `.env.sample` in each directory — AWS in `infra/<env>/.env`,
`GITHUB_TOKEN` and `OP_SERVICE_ACCOUNT_TOKEN` in `clusters/.env`. Everything else is a
1Password field `just seed-vault` creates for you to fill: a
[HyperSync API token](https://envio.dev/app/api-tokens), your indexer image, the DNS zone,
a Cloudflare token, SMTP settings and the Grafana, Postgres and Hasura logins. The backup
destination is read from `terraform output`, not typed.

## Running it

```sh
cd infra/<env> && just apply   # bring up the cluster — infra/<env>/README.md

cd ../../clusters
just seed-vault                # create the 1Password fields, then fill them in
just bootstrap                 # hand the cluster over to Flux
just show-details              # print the Grafana, Hasura and Postgres logins
```

Omit the `<env>/<cluster>` argument to any `clusters/` recipe and it opens an fzf picker
over the entrypoints that exist; `seed-vault` picks over environments instead.

## Going deeper

Day-two operations — sizing nodes, dedicating one to a workload, Talos and Kubernetes
upgrades, how the backup bucket is wired — are in
[`infra/<env>/README.md`](infra/staging/README.md). The README's
[layout table](README.md#layout) points at the rest.

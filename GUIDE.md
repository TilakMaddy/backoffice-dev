# Setup guide

From nothing to a running indexer: a [Talos](https://www.talos.dev/) Kubernetes cluster on
EC2, with Postgres, Hasura, your indexer, TLS, DNS, dashboards and alerts on your own
domain. See the [README](README.md) for what the stack is and what it gives you.

The bring-up comes in three parts:

| | where | what it does |
|---|---|---|
| Before you start | your laptop, GitHub | tools, accounts, your copy of this repo, your indexer image |
| Phase 1: infrastructure | `infra/staging` | Terraform builds the cluster and the backup bucket |
| Phase 2: cluster | `clusters` | 1Password holds the secrets, Flux converges everything else |

Phase 1 and Phase 2 are independent enough to keep in two terminal sessions, one parked in
`infra/staging` and one in `clusters`. Phase 2 reads Terraform's outputs, so run Phase 1
first and keep its terminal around.

## Environments, and the branch rule

Every command below is written for the `staging` environment and the cluster that ships
with it, `us-west-2-aws-backoffice-dataplane`. `production` has the same shape end to end:
its own `infra/production/`, its own entrypoint under `clusters/entrypoints/production/`,
its own `production/*` fields in the vault. It is covered in
[Doing it again for production](#doing-it-again-for-production) once staging is up.
`local` is a kind cluster (`infra/local`) for trying things without an AWS bill.

One branch per environment, and you have to be standing on it. The branch is not written
down anywhere you can edit. `just bootstrap` reads the branch your working tree is
currently on, bootstraps the cluster against that, and commits `flux-system` back to it.
From then on the cluster follows that branch, so every push to it is a deploy.

| environment | branch | before bootstrapping |
|---|---|---|
| staging | `staging` | `git checkout staging` |
| production | `production` | `git checkout production` |

`dev` is where you work. Merge `dev` into `staging` to ship to staging, and `staging` into
`production` once it has proved itself. Bootstrap staging while sitting on `production`
and the staging cluster will follow production's branch, with nothing to warn you, so
check `git rev-parse --abbrev-ref HEAD` first, every time.

## Before you start

### 1. Install the tools

```sh
brew install terraform awscli just jq fzf kubectl helm \
  fluxcd/tap/flux 1password-cli siderolabs/tap/talosctl
```

**Next:** `just --list` inside `infra/staging` and inside `clusters` should both work.

### 2. Get the accounts

Collect all of these before you start. Phase 2 stalls without any one of them.

| you need | why |
|---|---|
| An AWS account, and a profile that can create VPC, EC2, S3 and IAM resources | Phase 1 builds everything there |
| A GitHub account | this repo is a template, and Flux pushes to your copy of it |
| A 1Password account, one vault, and a service account token | every secret the cluster reads lives there |
| A DNS zone on Cloudflare, either a whole domain or a subdomain you delegate | Grafana, Hasura and Postgres are published under `*.<zone>` |
| A HyperSync API token from [envio.dev/app/api-tokens](https://envio.dev/app/api-tokens) | the only thing you need from Envio; there is no cloud plan involved |
| An SMTP sender such as [Resend](https://resend.com) | Grafana emails alerts through it |

### 3. Make your own copy of this repo

This repo is a GitHub template. Take a copy rather than cloning it directly, because Flux
commits to the repo it bootstraps from and that repo has to be yours.

```sh
gh repo create <you>/<your-indexer-infra> \
  --template TilakMaddy/hyperindex-openinfra --private --clone --include-all-branches
cd <your-indexer-infra>
git branch -a          # expect dev, staging, production
```

Or on GitHub: Use this template → Create a new repository, tick Include all branches, then
`git clone` it.

**Input:** a repository name.

**Output:** your own repo, cloned locally, with all three branches.

**Next:** three things Phase 2 depends on, so get them right now:

- Take all the branches. A template copy defaults to the default branch only, and
  `staging` and `production` are the branches their clusters follow. If you ended up with
  just one, create them: `git checkout -b staging && git push -u origin staging`, same for
  `production`.
- `origin` has to be a github.com remote. `flux bootstrap github` is what runs, and
  `clusters/scripts/lib.sh` reads the owner and repository straight off that URL.
- Flux bootstraps the branch you are on and pushes a commit to it. The branch has to exist
  on the remote (`git push -u origin <branch>`), and you cannot be on a detached HEAD.

### 4. Build your indexer image

This repo runs an indexer image that it does not contain. The image is yours: your
`config.yaml`, your `schema.graphql`, your handlers.

Start from the companion template, a normal Envio scaffold plus the few files needed to
ship it as a container:

https://github.com/TilakMaddy/my-envio-indexer

| file it adds | why it matters here |
|---|---|
| `Dockerfile` | two-stage build (`pnpm install` + `pnpm codegen`, then a slim runtime) that ships the indexer as an image, with restart handling for schema incompatibilities |
| `.dockerignore` | keeps `.git`, `node_modules`, `.env` and build artifacts out of the build context |
| `.github/workflows/release.yml` | builds `amd64` + `arm64` and pushes to GitHub Container Registry on every branch update |
| `justfile` | `just build [tag]` locally, `just deploy-kind [tag]` against a kind cluster |

Everything else there is stock `envio init` output. If you already have an indexer repo,
copy those four files into it instead of starting over.

**Output:** a pullable image ref such as `ghcr.io/<you>/my-envio-indexer:latest`.

**Next:** write it down. Phase 2 asks for exactly this string, and the cluster needs the
image to satisfy four conditions:

- It is public, or at least pullable without credentials, since no `imagePullSecret` is
  configured.
- It serves `/healthz` and `/metrics` on port 9898. The startup, readiness and liveness
  probes and the Prometheus `ServiceMonitor` all hit that port
  (`clusters/apps/chain-indexer/04-indexer/indexer.yaml`).
- It takes its configuration from the environment. The manifest supplies `ENVIO_PG_*`,
  `ENVIO_HASURA`, `HASURA_GRAPHQL_ENDPOINT` / `_ROLE` / `_ADMIN_SECRET`, `ENVIO_API_TOKEN`
  and `ENVIO_INDEXER_PORT`, so do not bake any of them into the image.
- It uses a tag you keep pushing to. Keel polls the tag (`INDEXER_KEEL_*` in the
  entrypoint's `main.yaml`) and rolls the indexer forward when the digest changes, which
  is why `:latest` works well here.

## Phase 1: stand up the infrastructure

Terminal A, from `infra/staging`. Nothing here touches 1Password, GitHub or Flux; it is
Terraform and AWS only.

```sh
git checkout staging
cd infra/staging
```

Terraform does not care which branch you are on, but everything you edit from here lands
in commits, and those commits have to end up on the branch this cluster will follow.

### 1.1 Point Terraform at your AWS account

```sh
cp .env.sample .env
$EDITOR .env
```

**Input:** whichever `AWS_*` variables your setup needs. `.env.sample` documents the
`AWS_PROFILE` + `credential_process` pattern, though a plain `AWS_PROFILE=` or static keys
work just as well.

**Output:** `infra/staging/.env`, which the justfile loads automatically (`set dotenv-load`).

**Next:** `aws sts get-caller-identity` should print the account you expect.

### 1.2 Describe the cluster you want

```sh
$EDITOR main.tf config.json
```

**Input:** three things in `main.tf`'s `locals` block, which have to agree with
`config.json`:

| | |
|---|---|
| `cluster_name` | the cluster key in `config.json` |
| `region` | the cluster's region |
| `pg_backups_bucket` | change this one. S3 bucket names are globally unique, so `oatlabs-backoffice-pg-backups-staging` is already taken |

Then `config.json`: `region`, `vpc_cidr`, the subnet/AZ map, and each node's
`instance_type` and `root_volume_size`. Sizing, adding nodes and dedicating a node to a
workload are covered in [`infra/staging/README.md`](infra/staging/README.md).

Three things there are load-bearing. Change the sizes freely, but keep the shape:

- A worker with `"roles": ["general"]`, which the indexer and Hasura are pinned to.
- Three workers with `"roles": ["postgres"]` and the
  `node-role.kubernetes.io/postgres:NoSchedule` registration taint. Postgres runs there,
  and `main.tf` attaches the backup-bucket IAM policy to exactly those nodes
  (`local.postgres_nodes`).
- A worker with `"roles": ["observability"]` and its matching taint, where Grafana,
  Prometheus and Loki land.

**Output:** a config that describes your cluster.

**Next:** the cluster key you settle on is the name every later command uses, including
Phase 2's entrypoint directory. Renaming it means renaming
`clusters/entrypoints/staging/us-west-2-aws-backoffice-dataplane/` to match.

### 1.3 Build it

```sh
just apply
```

**Input:** nothing. `terraform init` and `terraform apply -auto-approve` run for you.

**Output:** the VPC, the Talos cluster and the backup bucket. `apply` ends with
`fetch-configs`, so the credentials for every cluster in `config.json` are written on the
way out:

```
.kube/us-west-2-aws-backoffice-dataplane.config      # kubectl
.talos/us-west-2-aws-backoffice-dataplane.config     # talosctl
```

**Next:** leave those files where they are. Phase 2 derives the path from the target
(`infra/<env>/.kube/<cluster>.config`) rather than being told it. Expect about 10 minutes.

### 1.4 Confirm the cluster is up

```sh
export KUBECONFIG=.kube/us-west-2-aws-backoffice-dataplane.config
kubectl get nodes
terraform output pg_backups_destination
```

**Output:** every control-plane and worker node `Ready`, and an `s3://…` bucket URL.

**Next:** Phase 2 never asks you to type that bucket URL, because `seed-vault` reads it out
of `terraform output` itself. Two consequences:

- Phase 1 has to have succeeded before you run `seed-vault`, or the `pg-backup-*` fields
  get skipped. Rerunning `seed-vault` later fixes that; it is idempotent.
- Terraform state is local and gitignored, so run Phase 2 on the same machine, or move the
  state to a remote backend first.

To fetch the kubeconfig again later without an apply:
`just fetch-config us-west-2-aws-backoffice-dataplane`.

## Phase 2: bring up the cluster

Terminal B, from `clusters`, on the same `staging` branch.

```sh
git checkout staging
cd clusters
```

This phase fills 1Password, commits the entrypoint, and hands the cluster to Flux.

### 2.1 Supply the two tokens

```sh
cp .env.sample .env
$EDITOR .env
set -a && source .env && set +a
```

**Input:** two secrets.

| | |
|---|---|
| `GITHUB_TOKEN` | a PAT with `repo` scope, on your copy of this repo. `flux bootstrap` commits the `flux-system` directory and installs a deploy key with it |
| `OP_SERVICE_ACCOUNT_TOKEN` | a 1Password service account token with read access to your vault. This is the cluster's credential rather than yours, and External Secrets uses it to pull every other secret |

**Output:** both exported in this shell. The `clusters` justfile does not load `.env` for
you, hence the `source`. If you keep `op://` references in `.env` instead of literal
values, prefix the commands with `op run --env-file=.env --` instead.

**Next:** `echo ${GITHUB_TOKEN:+set} ${OP_SERVICE_ACCOUNT_TOKEN:+set}` should print
`set set`.

### 2.2 Point the entrypoint at your vault

```sh
$EDITOR entrypoints/staging/us-west-2-aws-backoffice-dataplane/bootstrap.yaml
$EDITOR entrypoints/staging/us-west-2-aws-backoffice-dataplane/main.yaml
```

**Input:** in `bootstrap.yaml`,

| key | |
|---|---|
| `OP_VAULT` | your 1Password vault's name. Ships as `MyIndexer`, so either name your vault that or change it here. Every entrypoint has to name the same vault; `seed-vault` refuses to guess if they disagree |
| `ACME_ENV` | `staging` while you are finding your feet, `production` for real certificates. Let's Encrypt rate-limits production issuance and staging does not |
| `GRAFANA_ALLOWED_CIDRS` | who may reach Grafana. Ships wide open as `'["0.0.0.0/0"]'` |

and in `main.yaml`, `CHAIN_INDEXER_HASURA_ALLOWED_CIDRS` and
`CHAIN_INDEXER_PG_ALLOWED_PRINCIPALS`, which decide who may reach the GraphQL endpoint and
the Postgres endpoints. Both also ship wide open. The gateway denies everything not on
these lists, so narrow them to your own addresses.

**Output:** an entrypoint that names your vault.

**Next:** the directory name (`us-west-2-aws-backoffice-dataplane`) has to match the
cluster key from step 1.2, because that is how the kubeconfig path is derived. The
`OP_VAULT_*` values are addresses inside the vault; their field names are fixed by
`seed-vault`, and only the `staging/` prefix is yours. See
[`clusters/entrypoints/README.md`](clusters/entrypoints/README.md).

### 2.3 Commit and push the entrypoint

```sh
cd ..
git add clusters/entrypoints/staging infra/staging/config.json infra/staging/main.tf
git commit -m "staging: point the entrypoint at my vault and cluster"
git push origin staging
cd clusters
```

**Input:** the edits from 2.2, and the Terraform config from 1.2 for good measure.

**Output:** your entrypoint on the `staging` branch of your repo.

**Next:** Flux reconciles the repository, not your working tree. `just bootstrap` commits
only the `flux-system` directory it generates, so `bootstrap.yaml` and `main.yaml` are
yours to commit. Leave them uncommitted and the cluster converges against whatever the
template shipped: the `MyIndexer` vault name, the wide-open CIDRs, someone else's
settings. The same holds for every later change, since editing a variable does nothing
until it is pushed to this branch.

### 2.4 Create the 1Password fields

```sh
op signin          # as yourself, not the service account
just seed-vault staging
```

**Input:** the env name (omit it and you get an fzf picker). You have to be signed in to
`op` as a human with write access, because seeding writes and the service account is
read-only, which is why the script unsets `OP_SERVICE_ACCOUNT_TOKEN` before it runs.

**Output:** a Secure Note titled `staging` in your vault, holding 18 fields, and a
checklist of what still needs you:

```
created  MyIndexer/staging with 18 fields

fill in by hand, per item:
    cluster-zone *
    txt-owner-id *
    ...
* holds the REPLACE_ME placeholder (11 of 11)
```

**Next:** fill the starred ones, and leave everything else in the item alone.

### 2.5 Fill in the eleven fields

Open the `staging` item in 1Password and replace each `REPLACE_ME-…` value:

| field | what to put there |
|---|---|
| `cluster-zone` | the DNS zone on Cloudflare that this cluster owns, for example `indexer.example.com`. Everything is published beneath it: `grafana.<zone>`, `hasura-chain-indexer.<zone>`, `postgres-chain-indexer-rw.<zone>`, `postgres-chain-indexer-ro.<zone>`. A wildcard certificate is issued for `*.<zone>`, so give each cluster its own zone or subdomain |
| `txt-owner-id` | any short string unique to this cluster, for example `staging-usw2`. external-dns stamps it into the TXT records it owns so it can tell its own records from everyone else's. Changing it on a live cluster orphans the records the old id owned |
| `indexer-image-name` | the image ref from step 4 of *Before you start*, such as `ghcr.io/<you>/my-envio-indexer:latest`, tag included |
| `cloudflare-api-token` | a token that can edit DNS in that zone; see the note below. Cloudflare → My Profile → API Tokens → Create Token, permissions Zone : DNS : Edit and Zone : Zone : Read, Zone Resources scoped to your zone |
| `envio-token` | a HyperSync API token from [envio.dev/app/api-tokens](https://envio.dev/app/api-tokens) |
| `acme-email` | your email address, for the Let's Encrypt account. Expiry and policy notices go here |
| `alert-email-to` | where Grafana sends alerts. A distribution list or an on-call address, not necessarily yours |
| `grafana-smtp-host` | `host:port`, port included, for example `smtp.resend.com:587`. Grafana is configured for mandatory StartTLS, so use the submission port |
| `grafana-smtp-user` | the SMTP username. For Resend that is literally `resend` |
| `grafana-smtp-from-address` | the From address, on a domain your SMTP provider has verified, for example `alerts@example.com`. Unverified senders silently fail to deliver |
| `resend-smtp-password` | the SMTP password, which for Resend is an API key |

> The Cloudflare token is the one people get wrong. It needs write access to DNS, not
> read. Two components use it and both write: cert-manager creates and then deletes a
> `_acme-challenge` TXT record to prove you own the zone, and external-dns creates,
> updates and deletes the A/CNAME/TXT records behind every hostname. Cloudflare's Edit
> zone DNS template gives you the right pair, `Zone : DNS : Edit` plus `Zone : Zone :
> Read`, so start from that and set Zone Resources → Include → Specific zone → your zone
> so the token cannot touch anything else. A token missing `DNS : Edit` leaves `underlay`
> stuck with a certificate that never goes Ready and external-dns logging 403s; a token
> missing `Zone : Read` cannot find the zone at all.

Leave these alone, because `seed-vault` generated them: `grafana-admin-username`
(`admin`), `grafana-admin-password`, `chain-indexer-pg-password`,
`chain-indexer-pg-superuser-password`, `chain-indexer-hasura-admin-secret`. They are
32-char alphanumerics, alphanumeric on purpose because the Postgres password is
interpolated raw into a connection URI. You never need to type them, since
`just show-details` reads them back.

Leave these alone too, because Terraform owns them: `pg-backup-destination` and
`pg-backup-region` are copied from `terraform output` in `infra/staging` on every run of
`seed-vault`, so the bucket the cluster backs up to cannot drift from the bucket that
exists.

Then confirm:

```sh
just seed-vault staging
```

**Output:** `ok       MyIndexer/staging, all 18 fields present`, and a checklist with no
`*` lines left. A `skipped … pg-backup-*` line means Phase 1's Terraform state was not
readable, so go back to 1.4.

### 2.6 Hand the cluster to Flux

```sh
git rev-parse --abbrev-ref HEAD     # must say: staging
just bootstrap staging/us-west-2-aws-backoffice-dataplane
```

**Input:** the `<env>/<cluster>` target, or an fzf picker over the entrypoints that exist
if you omit it. Both tokens from 2.1 have to be in the environment, and you have to be on
the `staging` branch, since that is the branch this cluster will follow from now on and it
is taken from your working tree rather than from the target you typed.

**Output:** the script plants `OP_SERVICE_ACCOUNT_TOKEN` in the cluster as the
`onepassword-token` secret, resumes anything a previous `destroy` left suspended, then
runs `flux bootstrap github`, which installs Flux and commits the `flux-system` directory
to your repo on the current branch.

**Next:** from here everything is Flux's, and nothing else is applied by hand.

### 2.7 Watch it converge

```sh
export KUBECONFIG=../infra/staging/.kube/us-west-2-aws-backoffice-dataplane.config
flux get kustomizations --watch
```

**Output:** the stages come up in dependency order, each waiting on the one before it:

```
bootstrap → secrets → underlay → observability → common → apps
```

**Next:** the first convergence takes a while, since it pulls every operator's chart and
waits for cert-manager to complete a DNS-01 challenge and issue the wildcard certificate.
If it sits on `underlay`, that is almost always the certificate: check the Cloudflare
token's permissions, and check that the zone in `cluster-zone` really is on the account
the token belongs to.

```sh
kubectl get certificate -A          # is the wildcard Ready?
flux get all -A --status-selector ready=false
```

## Verify

```sh
just show-details staging
```

**Input:** the env, or `<env>/<cluster>` if an env holds more than one. Everything printed
is read live out of 1Password, so this works from any machine signed in to `op`, and does
not need a kubeconfig.

**Output:** every way into the cluster.

| | |
|---|---|
| Grafana | `https://grafana.<zone>`, with the generated admin login. Dashboards for indexer health and the cluster underneath it, and alerts already wired to your email |
| Hasura | the console and the `/v1/graphql` endpoint. The admin secret is the API key, required on every request, and Hasura has no usernames |
| Postgres | `-rw` (primary) and `-ro` (replicas) hostnames, port 5432, database `indexer-db`, with a ready-made connection URI and `psql` command for each |

Two things that trip people up here:

- With `ACME_ENV: staging`, certificates chain to the Let's Encrypt staging root, which
  nothing trusts: browsers warn, and `psql` needs the CA bundled at
  `clusters/tests/stg-root-x1.pem` (`show-details` puts it in the command for you). Switch
  `ACME_ENV` to `production` when you are ready for real certificates.
- Access is gated at the gateway by the CIDR allowlists from 2.2, as you pushed them in
  2.3. If a URL times out from your laptop and the pods are healthy, that is the first
  thing to check.

Then confirm the indexer is actually indexing:

```sh
kubectl -n chain-indexer get pods
kubectl -n chain-indexer logs sts/indexer -f
```

Blocks should be advancing, and the chain-indexer folder in Grafana should be filling in.
A `CrashLoopBackOff` here is usually the image: either it is not public, or it is not
listening on 9898.

## Doing it again for production

Production runs the same two phases, against `infra/production` and the `production`
entrypoint, from the `production` branch. Do it once staging is converging. Staging is
where you find out that a Cloudflare token is missing a permission, and Let's Encrypt's
production endpoint is rate-limited while its staging one is not.

What differs:

| | staging | production |
|---|---|---|
| branch | `staging` | `production`, so `git checkout production` before both phases |
| terraform | `infra/staging` | `infra/production`, with its own `.env` and `config.json`, and a `pg_backups_bucket` name that has to be globally unique too |
| vault | the item titled `staging`, fields `staging/*` | a second item titled `production`, fields `production/*`. Run `just seed-vault production` and fill the same eleven values again |
| certificates | `ACME_ENV: staging`, an untrusted root with no rate limit | `ACME_ENV: production`, real Let's Encrypt certificates, already set in the production entrypoint |
| DNS zone | `cluster-zone` for staging | a different zone or subdomain. Two clusters sharing one zone means two external-dns instances writing the same records |
| `txt-owner-id` | unique to staging | a different value again, which is what keeps the two external-dns instances from claiming each other's records |
| sizing | `PG_STORAGE: 1Gi`, `PG_WAL_STORAGE: 1Gi`, retention `5d`, flux every `2m` | `PG_STORAGE: 20Gi`, `PG_WAL_STORAGE: 10Gi`, retention `30d`, flux every `5m`, already set in `entrypoints/production/…/main.yaml` |
| allowlists | fine left open while you test | narrow `GRAFANA_ALLOWED_CIDRS`, `CHAIN_INDEXER_HASURA_ALLOWED_CIDRS` and `CHAIN_INDEXER_PG_ALLOWED_PRINCIPALS` to the addresses that should reach it |

The whole run, end to end:

```sh
git checkout production && git pull

# Phase 1 — terminal A
cd infra/production
cp .env.sample .env && $EDITOR .env        # AWS profile
$EDITOR main.tf config.json                # cluster_name, region, a unique pg_backups_bucket
just apply

# Phase 2 — terminal B, at the repo root, on the production branch
cd clusters
set -a && source .env && set +a
$EDITOR entrypoints/production/us-west-2-aws-backoffice-dataplane/bootstrap.yaml   # OP_VAULT, ACME_ENV
$EDITOR entrypoints/production/us-west-2-aws-backoffice-dataplane/main.yaml        # CIDRs, sizing

cd .. && git add -A && git commit -m "production: entrypoint" && git push origin production && cd clusters

just seed-vault production                 # then fill the eleven production/* fields
git rev-parse --abbrev-ref HEAD            # must say: production
just bootstrap production/us-west-2-aws-backoffice-dataplane
just show-details production
```

One vault, two items: `seed-vault` writes a separate item per environment into the same
`OP_VAULT`, so staging and production never share a password, a zone, a token or a
database. The vault name itself is the one value the two entrypoints have to agree on, and
if they name different vaults in `bootstrap.yaml`, `seed-vault` refuses to guess which one
you meant.

Promoting a change from then on is a merge: merge `dev` into `staging`, watch the staging
cluster converge, then merge `staging` into `production`. Flux is watching both branches,
so the push is the deploy. The indexer image is the exception, since Keel rolls that
forward on its own when you push a new image to the tag in `indexer-image-name`.

## Tearing it down

This applies to either environment. Substitute `staging` or `production` throughout, be on
that environment's branch, and keep its kubeconfig at
`infra/<env>/.kube/<cluster>.config`.

Order matters. Terraform does not know about the load balancers the gateway created, so
the cluster has to unwind first:

```sh
git checkout <env>

cd clusters
just destroy <env>/us-west-2-aws-backoffice-dataplane

cd ../infra/<env>
just destroy
```

The first deletes the Flux stages in reverse dependency order and waits for each inventory
to be garbage-collected, which is what releases the NLBs. The second removes the cluster,
the VPC, and the backup bucket with every backup in it, because `main.tf` sets
`force_destroy = true` on it. Copy anything you want to keep out of S3 first.

Your 1Password item survives, so rebuilding the same environment later starts from
`just seed-vault <env>` with the values already in place. Rerun it after the new
`terraform apply` so `pg-backup-destination` follows the new bucket.

## Going deeper

Day-two operations, including sizing nodes, dedicating one to a workload, Talos and
Kubernetes upgrades, and how the backup bucket is wired, are in
[`infra/staging/README.md`](infra/staging/README.md).

| | |
|---|---|
| [`clusters/entrypoints/README.md`](clusters/entrypoints/README.md) | what each entrypoint file declares, and the `OP_VAULT_*` contract |
| [`clusters/packages/layer-zero/README.md`](clusters/packages/layer-zero/README.md) | the platform package: its `platform-vars` interface and the three stages it creates |
| [`clusters/apps/README.md`](clusters/apps/README.md) | the chain-indexer app, and how the Postgres backup toggle works |
| [README layout table](README.md#layout) | the rest of the tree |

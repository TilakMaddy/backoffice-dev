# Run instructions

Requires `terraform`, `just`, `jq`, `helm`, `kubectl` and AWS credentials on your machine. Refer `.env.sample`.
 
Step 1: Bootstrap the Kubernetes infrastructure on AWS for all clusters in `config.json`.
`apply` ends with `fetch-configs`, so the Kubernetes and Talos credentials for every
cluster in `config.json` are written to `.kube/` and `.talos/` on the way out.
```sh
just apply
```

Step 2: Now you are ready to deploy apps with `kubectl` with the below configuration.
```bash
export KUBECONFIG=.kube/us-west-2-aws-backoffice-dataplane.config
```

Step 3: To use `talosctl` for cluster administration
```bash
export TALOSCONFIG=.talos/us-west-2-aws-backoffice-dataplane.config
```

To refresh one cluster's credentials without an apply — after a `terraform destroy` and
rebuild, or on a machine that has the state but not the files:
```sh
just fetch-config us-west-2-aws-backoffice-dataplane
```

# FAQ

## Create a new Kubernetes cluster

Add a cluster entry and fill up the nodes in `config.json`, then run `just apply`.

## Add capacity units to existing cluster

Add a node entry to an existig cluster in `config.json`, then run `just apply`.

## Dedicate a node to a workload

Give the node a taint to keep everything else off, a role so workloads can select it, and
any labels you want. Then run `just apply`.

```json
"node-1": {
  "instance_type": "c7i-flex.large",
  "root_volume_size": 30,
  "monitoring": false,
  "availability_zone": "us-west-2a",
  "registration_taints": [
    { "key": "node-role.kubernetes.io/postgres", "effect": "NoSchedule" }
  ],
  "roles": ["postgres"],
  "labels": { "oatlabs.oatmilk.work/tier": "db" }
}
```

`roles` and `labels` can be edited whenever you like. `registration_taints` cannot: they are
read only when the node registers, so a later edit fails the plan and tells you what to do
instead. That rigidity is the point here — the taint is on the node from the instant it
joins, so nothing can land on it in the meantime.

Tainting a **control plane** node also strands the EBS CSI controller, which is pinned there
and tolerates only `node-role.kubernetes.io/control-plane`.

## Dedicate a node to a workload, reversibly

Use `runtime_taints` when the dedication is one you expect to move — trialling a node for a
workload before committing to it, or shifting a reservation between nodes that already exist.
Same shape as `registration_taints`, but applied once the cluster is healthy and editable on
any apply.

```json
"node-0": {
  "instance_type": "c7i-flex.large",
  "root_volume_size": 30,
  "monitoring": false,
  "availability_zone": "us-west-2c",
  "runtime_taints": [
    { "key": "oatlabs.oatmilk.work/workload", "value": "ingress", "effect": "NoSchedule" }
  ],
  "roles": ["ingress"]
}
```

Only pods carrying the matching toleration land there:

```yaml
tolerations:
  - key: oatlabs.oatmilk.work/workload
    value: ingress
    effect: NoSchedule
```

Move the reservation by moving those four lines to another node and running `just apply`;
remove them to hand the node back to everything else.

To take a node out of service briefly, use `kubectl cordon` instead — that is what it is for.

The trade against `registration_taints` is the gap: between the node joining and Terraform
reaching the reconciler, the node carries no runtime taint, so a pod can land there on a
fresh bring-up. The same key and effect cannot be in both lists on one node — the plan
rejects it.

### If a NoExecute taint breaks the cluster

`runtime_taints` accepts `NoExecute`, and evicting the wrong thing can make the cluster
unhealthy. `terraform apply` then stops at the health check, which runs *before* the step
that would remove the taint, so re-applying will not fix it. Clear it by hand first:

```sh
export KUBECONFIG=.kube/us-west-2-aws-backoffice-dataplane.config
kubectl taint node <node> <key>:NoExecute-
```

Then remove it from `config.json` and `just apply`.

## Find a node by its config.json name

```sh
kubectl get nodes -L oatlabs.oatmilk.work/node-hint
kubectl get nodes -l oatlabs.oatmilk.work/node-hint=worker.node-1
```

The value is `<role>.<name>`, the same key Terraform uses in state.

## Upgrade Talos & Kubernetes versions

**Use `talosctl`, not just change versions in `config.json` and re-apply terraform configuration.**.

Refer

- [How to upgrade k8s](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes)

- [How to upgrade Talos](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/lifecycle-management/upgrading-talos#talosctl-upgrade)

- [Talos & Kubernetes version compatiblity](https://docs.siderolabs.com/talos/v1.13/getting-started/support-matrix)


**DO NOT SKIP**. 

A stale `kubernetes_version` in `config.json` can roll the control plane backwards the next time anything regenerates the machine config. Always manually upgrade the `talos_version` / `kubernetes_version` in `config.json` to match what the cluster runs.

## Postgres backups

`main.tf` creates `oatlabs-backoffice-pg-backups-production` and attaches a policy scoped to it onto the
instance-profile roles of the three `postgres` workers (`node-1`, `node-2`,
`node-3` in `config.json`). The CNPG barman-cloud sidecar authenticates through
IMDSv2 with no stored credential.

These are Talos clusters, not EKS, so there is no OIDC provider and no IRSA — the
node instance profile is the only AWS identity a pod can hold. Every pod on those
three nodes can therefore read and write the backup bucket. They carry
`node-role.kubernetes.io/postgres:NoSchedule` registration taints and only the
CNPG cluster tolerates them, which is what keeps that set to the Postgres pods.

The node names are listed in `local.postgres_nodes`, and the role names are
derived from `<namespace>/<cluster name>` the same way the module derives them. A
`data "aws_iam_role"` lookup sits in front of the attachment, so a naming change
upstream fails the plan naming the role it looked for rather than silently
attaching nothing.

## Module source

`main.tf` sources `oatlabs/k8s-lima/aws` from the Terraform registry, pinned to `0.0.3`.
Bumping it is a two-line change — `version` here and whatever `config.json` fields the new
release adds — and `terraform init -upgrade` to move the lock file.

To work against an unreleased change, point `source` at a local checkout and drop
`version`:

```hcl
module "marvel" {
  source = "/path/to/terraform-aws-k8s-lima"

  config = file("${path.module}/config.json")
}
```

Put it back before committing — a local path is not resolvable for anyone else, and
`.terraform.lock.hcl` does not record it.

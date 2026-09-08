Manifests of custom apps go here. You can assume the platform foundation has been successfully bootstrapped.

## Postgres backups

`PG_BACKUPS_ENABLED` in `cluster-vars` is read twice: as the `enabled` /
`isWALArchiver` flag on the Cluster's barman-cloud plugin entry, and as the last
path segment of the `pg-backups` Kustomization in `02-postgres/backups.yaml`. Its
value is therefore `"true"` or `"false"`, matching the directory names under
`02-postgres/backups/`.

`02-postgres/backups/kustomization.yaml` declares no resources, and that is
load-bearing. The `apps` Kustomization has no kustomization file of its own, so
Flux generates one by scanning the tree — and a sub-directory holding a
kustomization file is added as a single resource without being descended into.
The empty one therefore hides `true/` and `false/` from `apps`, leaving the
`pg-backups` Kustomization as the only thing that applies either. Delete it and
`apps` applies both variants at once.

When `PG_BACKUPS_ENABLED` is `"true"` the cluster also requires
`PG_BACKUP_DESTINATION`, `PG_BACKUP_REGION`, `PG_BACKUP_RETENTION` and
`PG_BACKUP_SCHEDULE`. Only `02-postgres/backups/true/` reads them, so a cluster
with backups off does not need them and local/kind does not declare them.
Nothing validates this.

`PG_BACKUP_SCHEDULE` is a six-field cron — seconds first — so daily at 03:00 UTC
is `0 0 3 * * *`.

Credentials come from the node, not from 1Password: the postgres nodes carry an
instance profile granting access to the backup bucket, and the ObjectStore sets
`s3Credentials.inheritFromIAMRole: true`. See `infra/<env>/README.md`.

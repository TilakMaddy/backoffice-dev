module "marvel" {
  source  = "oatlabs/k8s-lima/aws"
  version = "0.0.3"

  config = file("${path.module}/config.json")
}

locals {
  cluster_name = "us-west-2-aws-backoffice-dataplane"
  region       = "us-west-2"
  namespace    = "production"

  # Where base backups and WALs are replicated to. Change this one line to move
  # the copy; anything but local.region, since S3 rejects a rule that replicates
  # a bucket onto itself.
  replica_region = "us-east-2"

  name_prefix               = substr(uuidv5("oid", "${local.namespace}/${local.cluster_name}"), 0, 32)
  postgres_nodes            = ["node-1", "node-2", "node-3"]
  pg_backups_bucket         = "oatlabs-backoffice-pg-backups-${local.namespace}"
  pg_backups_replica_bucket = "oatlabs-backoffice-pg-backups-${local.namespace}-replica"

  tags = {
    Organization = "Marvel"
    Namespace    = local.namespace
    Provisioner  = "Terraform"
    Platform     = "OatLabs"
    ClusterName  = "${local.namespace}-${local.cluster_name}"
  }
}

resource "aws_s3_bucket" "pg_backups" {
  region = local.region
  bucket = local.pg_backups_bucket
  tags   = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "pg_backups" {
  region = local.region
  bucket = aws_s3_bucket.pg_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "pg_backups" {
  region = local.region
  bucket = aws_s3_bucket.pg_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pg_backups" {
  region = local.region
  bucket = aws_s3_bucket.pg_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "pg_backups" {
  region = local.region
  bucket = aws_s3_bucket.pg_backups.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# The replica. Same settings as the source bucket above, in another region: a
# faithful copy is only useful if it is protected the same way. Nothing writes
# here directly -- S3 replication is the only producer.
resource "aws_s3_bucket" "pg_backups_replica" {
  region = local.replica_region
  bucket = local.pg_backups_replica_bucket
  tags   = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

# Required on both ends: S3 replicates object versions, so neither bucket can be
# unversioned.
resource "aws_s3_bucket_versioning" "pg_backups_replica" {
  region = local.replica_region
  bucket = aws_s3_bucket.pg_backups_replica.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "pg_backups_replica" {
  region = local.replica_region
  bucket = aws_s3_bucket.pg_backups_replica.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 rather than KMS, matching the source. A KMS key would have to be
# replicated too, and the replication role would need kms:Decrypt in the source
# region and kms:Encrypt in the replica's.
resource "aws_s3_bucket_server_side_encryption_configuration" "pg_backups_replica" {
  region = local.replica_region
  bucket = aws_s3_bucket.pg_backups_replica.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = true
  }
}

# Mirrors the source lifecycle. Delete markers are replicated (see the rule
# below), so barman-cloud expiring a backup lands here as a delete marker and
# this rule is what actually reclaims the space.
resource "aws_s3_bucket_lifecycle_configuration" "pg_backups_replica" {
  region = local.replica_region
  bucket = aws_s3_bucket.pg_backups_replica.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

data "aws_caller_identity" "current" {}

# S3 replicates as this role, not as whoever wrote the object, so it is the one
# identity that needs read on the source and write on the replica. The two
# source conditions stop any other account from using it as a confused deputy.
resource "aws_iam_role" "pg_backups_replication" {
  name        = "${local.name_prefix}-pg-backups-replication"
  path        = "/"
  description = "Assumed by S3 to replicate the postgres backup bucket to ${local.replica_region}"
  tags        = local.tags

  assume_role_policy = jsonencode(
    {
      Version = "2012-10-17",
      Statement = [
        {
          Effect = "Allow",
          Principal = {
            Service = "s3.amazonaws.com"
          },
          Action = "sts:AssumeRole",
          Condition = {
            StringEquals = {
              "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            },
            ArnLike = {
              "aws:SourceArn" = aws_s3_bucket.pg_backups.arn
            }
          }
        }
      ]
    }
  )
}

resource "aws_iam_policy" "pg_backups_replication" {
  name        = "${local.name_prefix}-pg-backups-replication-policy"
  path        = "/"
  description = "IAM policy for S3 to read object versions from the postgres backup bucket and write them to the ${local.replica_region} replica"
  tags        = local.tags

  policy = jsonencode(
    {
      Version = "2012-10-17",
      Statement = [
        {
          Effect = "Allow",
          Action = [
            "s3:GetReplicationConfiguration",
            "s3:ListBucket"
          ],
          Resource = aws_s3_bucket.pg_backups.arn
        },
        {
          Effect = "Allow",
          Action = [
            "s3:GetObjectVersionForReplication",
            "s3:GetObjectVersionAcl",
            "s3:GetObjectVersionTagging"
          ],
          Resource = "${aws_s3_bucket.pg_backups.arn}/*"
        },
        {
          Effect = "Allow",
          Action = [
            "s3:ReplicateObject",
            "s3:ReplicateDelete",
            "s3:ReplicateTags"
          ],
          Resource = "${aws_s3_bucket.pg_backups_replica.arn}/*"
        }
      ]
    }
  )
}

resource "aws_iam_role_policy_attachment" "pg_backups_replication" {
  role       = aws_iam_role.pg_backups_replication.name
  policy_arn = aws_iam_policy.pg_backups_replication.arn
}

# Replication only ever applies to objects written after this is in place --
# there is no backfill here. infra/production/README.md has the one-off sync for
# whatever was already in the bucket.
resource "aws_s3_bucket_replication_configuration" "pg_backups" {
  region = local.region
  bucket = aws_s3_bucket.pg_backups.id
  role   = aws_iam_role.pg_backups_replication.arn

  # Versioning has to exist on both ends before S3 accepts the configuration, and
  # nothing in the arguments below references either versioning resource, so this
  # is the only thing ordering them.
  depends_on = [
    aws_s3_bucket_versioning.pg_backups,
    aws_s3_bucket_versioning.pg_backups_replica,
  ]

  rule {
    id       = "pg-backups-to-${local.replica_region}"
    status   = "Enabled"
    priority = 0

    # Every object: base backups and WALs both.
    filter {}

    # Enabled so the replica tracks the source. barman-cloud deleting an expired
    # backup lands here as a delete marker, and the replica's lifecycle rule then
    # reclaims the version. Disabling this turns the replica into an append-only
    # archive that nothing ever prunes -- which is more protection against an
    # accidental delete, at a cost that grows forever on a bucket taking a
    # continuous WAL stream. S3 never replicates deletes of a specific version
    # either way, so the two buckets cannot be made to diverge by a hard delete.
    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.pg_backups_replica.arn
      storage_class = "STANDARD"
    }
  }
}

resource "aws_iam_policy" "pg_backups" {
  name        = "${local.name_prefix}-postgres-backups-policy"
  path        = "/"
  description = "IAM policy for the postgres nodes to allow the CNPG barman-cloud plugin to read and write base backups and WALs, and to read them back from the cross-region replica"
  tags        = local.tags

  policy = jsonencode(
    {
      Version = "2012-10-17",
      Statement = [
        {
          Effect = "Allow",
          Action = [
            "s3:ListBucket",
            "s3:GetBucketLocation",
            "s3:ListBucketMultipartUploads"
          ],
          Resource = aws_s3_bucket.pg_backups.arn
        },
        {
          Effect = "Allow",
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:AbortMultipartUpload",
            "s3:ListMultipartUploadParts"
          ],
          Resource = "${aws_s3_bucket.pg_backups.arn}/*"
        },
        {
          Effect = "Allow",
          Action = [
            "s3:ListBucket",
            "s3:GetBucketLocation"
          ],
          Resource = aws_s3_bucket.pg_backups_replica.arn
        },
        {
          Effect = "Allow",
          Action = [
            "s3:GetObject"
          ],
          Resource = "${aws_s3_bucket.pg_backups_replica.arn}/*"
        }
      ]
    }
  )
}

data "aws_iam_role" "postgres_nodes" {
  for_each = toset(local.postgres_nodes)

  name       = "${local.name_prefix}-worker-${each.key}"
  depends_on = [module.marvel]
}

resource "aws_iam_role_policy_attachment" "pg_backups" {
  for_each = data.aws_iam_role.postgres_nodes

  role       = each.value.name
  policy_arn = aws_iam_policy.pg_backups.arn
}

output "talosconfigs" {
  description = "The generated talosconfig, per cluster. Keyed by the cluster's key in config.json, without the namespace prefix."
  value       = module.marvel.talosconfigs
  sensitive   = true
}

output "kubeconfigs" {
  description = "The generated kubeconfig, per cluster. Keyed by the cluster's key in config.json, without the namespace prefix."
  value       = module.marvel.kubeconfigs
  sensitive   = true
}

output "pg_backups_destination" {
  description = "The PG_BACKUP_DESTINATION for the flux entrypoint of this namespace."
  value       = "s3://${local.pg_backups_bucket}/"
}

output "pg_backups_region" {
  description = "The PG_BACKUP_REGION for the flux entrypoint of this namespace."
  value       = local.region
}

# Not read by seed-vault.sh -- CNPG only ever writes to the primary. These are
# the two values a restore from the replica needs.
output "pg_backups_replica_destination" {
  description = "The destinationPath of the cross-region replica of the backup bucket."
  value       = "s3://${local.pg_backups_replica_bucket}/"
}

output "pg_backups_replica_region" {
  description = "The region the backup bucket is replicated to."
  value       = local.replica_region
}

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {}

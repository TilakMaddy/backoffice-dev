module "marvel" {
  source = "oatlabs/k8s-lima/aws"
  version = "0.0.1"

  config = file("${path.module}/config.json")
}

output "talosconfig" {
  description = "The generated talosconfig, per cluster."
  value       = module.marvel.talosconfig
  sensitive   = true
}

output "kubeconfig" {
  description = "The generated kubeconfig, per cluster."
  value       = module.marvel.kubeconfig
  sensitive   = true
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

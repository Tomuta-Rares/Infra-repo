terraform {
  cloud {
    organization = "aws-dev-rares"

    workspaces {
      name = "aws-dev"
    }
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }

    helm = {
      source = "hashicorp/helm"
    }

    tls = {
      source = "hashicorp/tls"
    }

    null = {
      source = "hashicorp/null"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "vpc" {
  source = "git::git@github.com:Tomuta-Rares/terraform-aws-modules.git//modules/vpc?ref=v0.2.1"

  name     = "dev-vpc"
  vpc_cidr = "10.0.0.0/16"

  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]

  availability_zones = ["eu-central-1a", "eu-central-1b"]
}

module "eks" {
  source = "git::git@github.com:Tomuta-Rares/terraform-aws-modules.git//modules/eks?ref=v0.2.6"

  cluster_name        = "dev-shopping-eks"
  subnet_ids          = module.vpc.public_subnet_ids
  node_subnet_ids     = module.vpc.public_subnet_ids
  node_instance_types = ["t3.small"]
}

data "aws_eks_cluster" "this" {
  name = module.eks.cluster_name

  depends_on = [
    module.eks
  ]
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name

  depends_on = [
    module.eks
  ]
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  depends_on = [
    module.eks
  ]
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true

  depends_on = [
    module.eks
  ]
}

resource "null_resource" "sealed_secrets_master_key" {
  depends_on = [
    module.eks
  ]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region} && kubectl apply -f ${path.module}/sealed-secrets-master-key.yaml"
  }
}

resource "null_resource" "argocd_root_app" {
  depends_on = [
    helm_release.argocd,
    null_resource.sealed_secrets_master_key
  ]

  provisioner "local-exec" {
    command = "kubectl apply -f ${path.module}/../../../../argocd/root/aws-root-app.yaml"
  }
}
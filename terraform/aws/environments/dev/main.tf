terraform {
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
  }
}

provider "aws" {
  region = var.aws_region
}

##### terraform cloud ##################
terraform {
  cloud {
    organization = "aws-dev-rares"

    workspaces {
      name = "aws-dev"
    }
  }
}
#######################################3#

module "vpc" {
  source = "git::git@github.com:Tomuta-Rares/terraform-aws-modules.git//modules/vpc?ref=v0.2.1"

  name     = "dev-vpc"
  vpc_cidr = "10.0.0.0/16"

  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]

  availability_zones = ["eu-central-1a", "eu-central-1b"]
}




module "eks" {
  source = "git::git@github.com:Tomuta-Rares/terraform-aws-modules.git//modules/eks?ref=v0.2.5"

  cluster_name        = "dev-shopping-eks"
  subnet_ids          = module.vpc.public_subnet_ids
  node_subnet_ids     = module.vpc.public_subnet_ids
  node_instance_types = ["t3.small"]
}

##### install argocd ##############################################################################
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
#####################################################################################################
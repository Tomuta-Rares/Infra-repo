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

# ============================================================
# VPC
# ============================================================

module "vpc" {
  source = "git::git@github.com:Tomuta-Rares/terraform-aws-modules.git//modules/vpc?ref=v0.2.1"

  name     = "dev-vpc"
  vpc_cidr = "10.0.0.0/16"

  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]

  availability_zones = [
    "eu-central-1a",
    "eu-central-1b"
  ]
}

# ============================================================
# EKS
# ============================================================

module "eks" {
  source = "git::git@github.com:Tomuta-Rares/terraform-aws-modules.git//modules/eks?ref=v0.2.8"

  cluster_name        = "dev-shopping-eks"
  subnet_ids          = module.vpc.public_subnet_ids
  node_subnet_ids     = module.vpc.public_subnet_ids
  node_instance_types = ["t3.small"]
}

# ============================================================
# EKS DATA SOURCES
# ============================================================

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

# ============================================================
# HELM PROVIDER
# ============================================================

provider "helm" {
  kubernetes = {
    host = data.aws_eks_cluster.this.endpoint

    cluster_ca_certificate = base64decode(
      data.aws_eks_cluster.this.certificate_authority[0].data
    )

    token = data.aws_eks_cluster_auth.this.token
  }
}

# ============================================================
# AWS LOAD BALANCER CONTROLLER
# ============================================================

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  wait    = true
  timeout = 600

  set = [
    {
      name  = "clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "region"
      value = var.aws_region
    },
    {
      name  = "vpcId"
      value = module.vpc.vpc_id
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = module.eks.aws_load_balancer_controller_role_arn
    }
  ]

  depends_on = [
    module.eks
  ]
}

# ============================================================
# INGRESS NGINX
# ============================================================

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true

  wait    = true
  timeout = 600

  set = [
    {
      name  = "controller.service.loadBalancerClass"
      value = "service.k8s.aws/nlb"
    },
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
      value = "internet-facing"
    }
  ]

  depends_on = [
    helm_release.aws_load_balancer_controller
  ]
}

# ============================================================
# CERT MANAGER
# ============================================================

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true

  wait    = true
  timeout = 600

  set = [
    {
      name  = "crds.enabled"
      value = "true"
    }
  ]

  depends_on = [
    module.eks
  ]
}

# ============================================================
# ARGOCD
# ============================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  wait    = true
  timeout = 600

  depends_on = [
    helm_release.aws_load_balancer_controller
  ]
}

# ============================================================
# SEALED SECRETS MASTER KEY
# ============================================================

resource "null_resource" "sealed_secrets_master_key" {
  triggers = {
    cluster_name = module.eks.cluster_name
    aws_region   = var.aws_region

    manifest_sha = filesha256(
      "${path.module}/sealed-secrets-master-key.yaml"
    )
  }

  depends_on = [
    module.eks
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    command = <<-EOT
      set -e

      KUBECONFIG_FILE="$(mktemp)"
      trap 'rm -f "$KUBECONFIG_FILE"' EXIT

      aws eks update-kubeconfig \
        --name "${module.eks.cluster_name}" \
        --region "${var.aws_region}" \
        --kubeconfig "$KUBECONFIG_FILE"

      kubectl \
        --kubeconfig "$KUBECONFIG_FILE" \
        apply \
        -f "${path.module}/sealed-secrets-master-key.yaml"
    EOT
  }
}

# ============================================================
# LOCAL DEV ROOT CA
# ============================================================

resource "null_resource" "local_dev_root_ca" {
  triggers = {
    cluster_name = module.eks.cluster_name
    aws_region   = var.aws_region

    manifest_sha = filesha256(
      "${path.module}/local-dev-root-ca-secret.yaml"
    )
  }

  depends_on = [
    helm_release.cert_manager
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    command = <<-EOT
      set -e

      KUBECONFIG_FILE="$(mktemp)"
      trap 'rm -f "$KUBECONFIG_FILE"' EXIT

      aws eks update-kubeconfig \
        --name "${module.eks.cluster_name}" \
        --region "${var.aws_region}" \
        --kubeconfig "$KUBECONFIG_FILE"

      kubectl \
        --kubeconfig "$KUBECONFIG_FILE" \
        apply \
        -f "${path.module}/local-dev-root-ca-secret.yaml"
    EOT
  }
}

# ============================================================
# ARGOCD ROOT APPLICATION
# ============================================================

resource "null_resource" "argocd_root_app" {
  triggers = {
    cluster_name = module.eks.cluster_name
    aws_region   = var.aws_region

    manifest_path = abspath(
      "${path.module}/../../../../argocd/root/aws-root-app.yaml"
    )
  }

  depends_on = [
    helm_release.argocd,
    helm_release.ingress_nginx,
    helm_release.cert_manager,
    null_resource.local_dev_root_ca,
    null_resource.sealed_secrets_master_key
  ]

  # ----------------------------------------------------------
  # CREATE
  # ----------------------------------------------------------

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    command = <<-EOT
      set -e

      KUBECONFIG_FILE="$(mktemp)"
      trap 'rm -f "$KUBECONFIG_FILE"' EXIT

      aws eks update-kubeconfig \
        --name "${self.triggers.cluster_name}" \
        --region "${self.triggers.aws_region}" \
        --kubeconfig "$KUBECONFIG_FILE"

      kubectl \
        --kubeconfig "$KUBECONFIG_FILE" \
        apply \
        -f "${self.triggers.manifest_path}"
    EOT
  }

  # ----------------------------------------------------------
  # DESTROY
  # ----------------------------------------------------------

  provisioner "local-exec" {
    when       = destroy
    on_failure = fail

    interpreter = ["/bin/bash", "-c"]

    command = <<-EOT
      set -e

      KUBECONFIG_FILE="$(mktemp)"
      trap 'rm -f "$KUBECONFIG_FILE"' EXIT

      aws eks update-kubeconfig \
        --name "${self.triggers.cluster_name}" \
        --region "${self.triggers.aws_region}" \
        --kubeconfig "$KUBECONFIG_FILE"

      echo "Preparing ArgoCD applications for deletion..."

      for app in $(
        kubectl \
          --kubeconfig "$KUBECONFIG_FILE" \
          -n argocd \
          get applications.argoproj.io \
          -o name 2>/dev/null
      ); do

        kubectl \
          --kubeconfig "$KUBECONFIG_FILE" \
          -n argocd \
          patch "$app" \
          --type merge \
          -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}' \
          || true
      done

      echo "Deleting ArgoCD root application..."

      kubectl \
        --kubeconfig "$KUBECONFIG_FILE" \
        delete \
        -f "${self.triggers.manifest_path}" \
        --ignore-not-found=true \
        --wait=true \
        --timeout=15m

      echo "Waiting for ArgoCD applications to disappear..."

      for i in $(seq 1 120); do

        REMAINING=$(
          kubectl \
            --kubeconfig "$KUBECONFIG_FILE" \
            -n argocd \
            get applications.argoproj.io \
            --no-headers 2>/dev/null \
            | wc -l
        )

        if [ "$REMAINING" -eq 0 ]; then
          echo "All ArgoCD applications deleted."
          exit 0
        fi

        echo "$REMAINING application(s) still deleting..."
        sleep 5
      done

      echo "ERROR: ArgoCD applications could not be cleaned up."
      exit 1
    EOT
  }
}
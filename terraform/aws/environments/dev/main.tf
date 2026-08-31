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
# EKS DATA
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
# HELM
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

  # Evitam race-ul cu webhook-ul AWS LB Controller.
  depends_on = [
    helm_release.aws_load_balancer_controller
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
  depends_on = [
    module.eks
  ]

  provisioner "local-exec" {
    command = "KCFG=$(mktemp) && aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region} --kubeconfig $KCFG && kubectl --kubeconfig $KCFG apply -f ${path.module}/sealed-secrets-master-key.yaml && rm -f $KCFG"
  }
}

# ============================================================
# LOCAL DEV ROOT CA
# ============================================================

resource "null_resource" "local_dev_root_ca" {
  depends_on = [
    helm_release.cert_manager
  ]

  provisioner "local-exec" {
    command = "KCFG=$(mktemp) && aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region} --kubeconfig $KCFG && kubectl --kubeconfig $KCFG apply -f ${path.module}/local-dev-root-ca-secret.yaml && rm -f $KCFG"
  }
}

# ============================================================
# PRE-DESTROY LOAD BALANCER CLEANUP
#
# Resource-ul nu face nimic la CREATE.
#
# La DESTROY:
# - clusterul exista
# - AWS LB Controller exista
# - ingress-nginx exista
# - VPC-ul exista
#
# Stergem Service-ul LoadBalancer si asteptam pana cand
# NLB-ul dispare din AWS.
# ============================================================

resource "null_resource" "load_balancer_cleanup" {
  triggers = {
    cluster_name = module.eks.cluster_name
    aws_region   = var.aws_region
  }

  depends_on = [
    helm_release.aws_load_balancer_controller,
    helm_release.ingress_nginx
  ]

  provisioner "local-exec" {
    when       = destroy
    on_failure = fail

    command = "KCFG=$(mktemp); aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.aws_region} --kubeconfig $KCFG; LB_HOST=$(kubectl --kubeconfig $KCFG get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true); kubectl --kubeconfig $KCFG delete svc ingress-nginx-controller -n ingress-nginx --ignore-not-found=true --wait=true --timeout=10m; if [ -n \"$LB_HOST\" ]; then LB_NAME=$(printf '%s' \"$LB_HOST\" | cut -d. -f1); echo \"Waiting for AWS load balancer $LB_NAME to disappear...\"; for i in $(seq 1 60); do if ! aws elbv2 describe-load-balancers --names \"$LB_NAME\" --region ${self.triggers.aws_region} >/dev/null 2>&1; then echo \"Load balancer deleted.\"; rm -f $KCFG; exit 0; fi; sleep 10; done; echo \"ERROR: Load balancer still exists after 10 minutes.\"; rm -f $KCFG; exit 1; fi; rm -f $KCFG"
  }
}

# ============================================================
# ARGOCD ROOT APP
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
    helm_release.cert_manager,
    null_resource.local_dev_root_ca,
    null_resource.sealed_secrets_master_key,

    # IMPORTANT:
    # Creeaza cleanup-ul inainte de root app.
    # La destroy ordinea se inverseaza:
    #
    # root app cleanup
    #       ↓
    # load balancer cleanup
    #       ↓
    # Helm / EKS / VPC
    null_resource.load_balancer_cleanup
  ]

  # CREATE
  provisioner "local-exec" {
    command = "KCFG=$(mktemp) && aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.aws_region} --kubeconfig $KCFG && kubectl --kubeconfig $KCFG apply -f ${self.triggers.manifest_path} && rm -f $KCFG"
  }

  # DESTROY
  #
  # Stergem mai intai aplicatiile ArgoCD si resursele lor.
  provisioner "local-exec" {
    when       = destroy
    on_failure = fail

    command = "KCFG=$(mktemp); aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.aws_region} --kubeconfig $KCFG; for APP in $(kubectl --kubeconfig $KCFG -n argocd get applications.argoproj.io -o name 2>/dev/null || true); do kubectl --kubeconfig $KCFG -n argocd patch $APP --type merge -p '{\"metadata\":{\"finalizers\":[\"resources-finalizer.argocd.argoproj.io\"]}}' || true; done; kubectl --kubeconfig $KCFG delete -f ${self.triggers.manifest_path} --ignore-not-found=true --wait=true --timeout=10m; for i in $(seq 1 60); do COUNT=$(kubectl --kubeconfig $KCFG -n argocd get applications.argoproj.io --no-headers 2>/dev/null | wc -l); if [ \"$COUNT\" -eq 0 ]; then echo \"ArgoCD applications deleted.\"; rm -f $KCFG; exit 0; fi; echo \"Waiting for $COUNT ArgoCD application(s)...\"; sleep 10; done; echo \"ERROR: ArgoCD applications still exist.\"; rm -f $KCFG; exit 1"
  }
}
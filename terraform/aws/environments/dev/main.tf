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
  source = "git::git@github.com:Tomuta-Rares/terraform-aws-modules.git//modules/eks?ref=v0.2.8"

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
  version          = "10.7.1"
  namespace        = "argocd"
  create_namespace = true

  wait    = true
  timeout = 900
  atomic  = true

  depends_on = [
    helm_release.aws_load_balancer_controller
  ]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.5.0"
  namespace  = "kube-system"

  wait    = true
  timeout = 900
  atomic  = true

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

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.15.1"
  namespace        = "ingress-nginx"
  create_namespace = true

  wait    = true
  timeout = 900
  atomic  = true

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

resource "null_resource" "sealed_secrets_master_key" {
  depends_on = [
    module.eks
  ]

  provisioner "local-exec" {
    command = <<-EOT
      KCFG=$(mktemp)
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig "$KCFG"

      kubectl --kubeconfig "$KCFG" apply \
        -f ${path.module}/sealed-secrets-master-key.yaml

      rm -f "$KCFG"
    EOT
  }
}

resource "null_resource" "argocd_root_app" {
  depends_on = [
    helm_release.argocd,
    helm_release.cert_manager,
    null_resource.local_dev_root_ca,
    null_resource.sealed_secrets_master_key
  ]

  provisioner "local-exec" {
    command = <<-EOT
      KCFG=$(mktemp)
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig "$KCFG"

      kubectl --kubeconfig "$KCFG" apply \
        -f ${path.module}/../../../../argocd/root/aws-root-app.yaml

      rm -f "$KCFG"
    EOT
  }
}


resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.21.1"
  namespace        = "cert-manager"
  create_namespace = true

  wait    = true
  timeout = 900
  atomic  = true

  set = [
    {
      name  = "crds.enabled"
      value = "true"
    }
  ]

  depends_on = [
    helm_release.aws_load_balancer_controller
  ]
}

resource "null_resource" "local_dev_root_ca" {
  depends_on = [
    helm_release.cert_manager
  ]

  provisioner "local-exec" {
    command = <<-EOT
      KCFG=$(mktemp)
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig "$KCFG"

      kubectl --kubeconfig "$KCFG" apply \
        -f ${path.module}/local-dev-root-ca-secret.yaml

      rm -f "$KCFG"
    EOT
  }
}


resource "null_resource" "load_balancer_cleanup" {
  triggers = {
    cluster_name = module.eks.cluster_name
    aws_region   = var.aws_region
  }

  depends_on = [
    helm_release.ingress_nginx,
    helm_release.aws_load_balancer_controller
  ]

  provisioner "local-exec" {
    when       = destroy
    on_failure = fail

    command = <<-EOT
      set -e

      echo "=== Preparing Kubernetes access ==="

      KCFG=$(mktemp)

      cleanup() {
        rm -f "$KCFG"
      }

      trap cleanup EXIT

      aws eks update-kubeconfig \
        --name "${self.triggers.cluster_name}" \
        --region "${self.triggers.aws_region}" \
        --kubeconfig "$KCFG"

      echo "=== Detecting ingress-nginx LoadBalancer ==="

      LB_HOST=$(kubectl \
        --kubeconfig "$KCFG" \
        -n ingress-nginx \
        get service ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
        2>/dev/null || true)

      echo "Load balancer hostname: $LB_HOST"

      LB_ARN=""

      if [ -n "$LB_HOST" ]; then
        LB_ARN=$(aws elbv2 describe-load-balancers \
          --region "${self.triggers.aws_region}" \
          --query "LoadBalancers[?DNSName=='$LB_HOST'].LoadBalancerArn | [0]" \
          --output text)

        if [ "$LB_ARN" = "None" ]; then
          LB_ARN=""
        fi
      fi

      echo "Load balancer ARN: $LB_ARN"

      echo "=== Deleting ingress-nginx LoadBalancer Service ==="

      kubectl \
        --kubeconfig "$KCFG" \
        -n ingress-nginx \
        delete service ingress-nginx-controller \
        --ignore-not-found=true \
        --wait=false

      if [ -n "$LB_ARN" ]; then
        echo "=== Waiting for AWS NLB deletion ==="

        aws elbv2 wait load-balancers-deleted \
          --region "${self.triggers.aws_region}" \
          --load-balancer-arns "$LB_ARN"

        echo "AWS NLB deleted."
      else
        echo "No AWS NLB found. Nothing to wait for."
      fi

      echo "=== LoadBalancer cleanup complete ==="
    EOT
  }
}
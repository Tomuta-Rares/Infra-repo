terraform {
  cloud {
    organization = "aws-dev-rares"

    workspaces {
      name = "aws-dns-global"
    }
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_route53_zone" "main" {
  name = var.domain_name

  tags = {
    Project   = "devops-level-up"
    ManagedBy = "terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route53_record" "apps" {
  for_each = var.public_subdomains

  zone_id = aws_route53_zone.main.zone_id
  name    = "${each.value}.${var.domain_name}"
  type    = "CNAME"
  ttl     = 60

  records = [var.nlb_dns_name]
}
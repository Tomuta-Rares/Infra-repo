variable "aws_region" {
  description = "AWS region used by the provider"
  type        = string
}

variable "domain_name" {
  description = "Public domain managed by Route53"
  type        = string
}

variable "nlb_dns_name" {
  description = "DNS hostname of the ingress-nginx AWS NLB"
  type        = string
}

variable "public_subdomains" {
  description = "Public application subdomains"
  type        = set(string)

  default = [
    "shopping",
    "auth",
    "grafana",
    "argocd"
  ]
}
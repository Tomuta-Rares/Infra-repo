output "cluster_role_arn" {
  value = aws_iam_role.eks_cluster.arn
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs where the EKS control plane will attach networking"
  type        = list(string)
}


variable "node_subnet_ids" {
  description = "Subnet IDs where EKS worker nodes will run"
  type        = list(string)
}

variable "node_instance_types" {
  description = "EC2 instance types for the EKS node group"
  type        = list(string)
  default     = ["t3.small"]
}
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  type    = string
  default = "pitstop-eks"
}

variable "cluster_name" {
  type    = string
  default = "pitstop"
}

variable "node_instance_type" {
  description = "Must be Free-Tier eligible on this account"
  type        = string
  default     = "m7i-flex.large"
}

variable "node_size" {
  type    = number
  default = 2
}

variable "db_password" {
  description = "Master password for the customer RDS instance"
  type        = string
  sensitive   = true
}

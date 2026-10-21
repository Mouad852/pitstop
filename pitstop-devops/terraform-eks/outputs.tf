output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --profile ${var.aws_profile}"
}

output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}

output "customer_db_endpoint" {
  value = aws_db_instance.customer.address
}

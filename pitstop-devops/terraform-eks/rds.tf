resource "aws_db_subnet_group" "customer" {
  name       = "${var.cluster_name}-customer-db"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "customer_db" {
  name_prefix = "${var.cluster_name}-customer-db-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "MySQL from EKS nodes"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "customer" {
  identifier     = "${var.cluster_name}-customer"
  engine         = "mysql"
  engine_version = "8.4.11"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "pitstop"
  username = "pitstop"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.customer.name
  vpc_security_group_ids = [aws_security_group.customer_db.id]
  publicly_accessible    = false
  multi_az                = false

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
}

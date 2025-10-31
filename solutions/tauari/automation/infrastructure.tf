# Terraform Infrastructure as Code
# Author: Tauari
# Date: 2025-10-31
# Purpose: Provision monitoring infrastructure (Prometheus, Grafana)

terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  backend "s3" {
    bucket = "betting-terraform-state"
    key    = "monitoring/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "vpc_id" {
  description = "VPC ID for monitoring infrastructure"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for monitoring instances"
  type        = list(string)
}

# Security Groups
resource "aws_security_group" "prometheus" {
  name        = "${var.environment}-prometheus-sg"
  description = "Security group for Prometheus"
  vpc_id      = var.vpc_id
  
  ingress {
    description = "Prometheus web UI"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]  # Internal VPC only
  }
  
  ingress {
    description = "Allow scraping from Prometheus"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "${var.environment}-prometheus-sg"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_security_group" "grafana" {
  name        = "${var.environment}-grafana-sg"
  description = "Security group for Grafana"
  vpc_id      = var.vpc_id
  
  ingress {
    description = "Grafana web UI"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Public access (use ALB + auth in production)
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "${var.environment}-grafana-sg"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# EC2 Instance for Prometheus
resource "aws_instance" "prometheus" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.medium"  # 2 vCPU, 4GB RAM
  subnet_id     = var.subnet_ids[0]
  
  vpc_security_group_ids = [aws_security_group.prometheus.id]
  
  root_block_device {
    volume_size = 100  # 100GB for metrics storage
    volume_type = "gp3"
  }
  
  user_data = templatefile("${path.module}/user_data_prometheus.sh", {
    environment = var.environment
  })
  
  tags = {
    Name        = "${var.environment}-prometheus"
    Environment = var.environment
    Role        = "monitoring"
    ManagedBy   = "Terraform"
  }
}

# EC2 Instance for Grafana
resource "aws_instance" "grafana" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.small"  # 2 vCPU, 2GB RAM
  subnet_id     = var.subnet_ids[0]
  
  vpc_security_group_ids = [aws_security_group.grafana.id]
  
  root_block_device {
    volume_size = 50  # 50GB for dashboards and data
    volume_type = "gp3"
  }
  
  user_data = templatefile("${path.module}/user_data_grafana.sh", {
    environment      = var.environment
    prometheus_url   = "http://${aws_instance.prometheus.private_ip}:9090"
  })
  
  tags = {
    Name        = "${var.environment}-grafana"
    Environment = var.environment
    Role        = "monitoring"
    ManagedBy   = "Terraform"
  }
}

# Data source for latest Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical
  
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Elastic IP for Grafana (optional, for public access)
resource "aws_eip" "grafana" {
  instance = aws_instance.grafana.id
  domain   = "vpc"
  
  tags = {
    Name        = "${var.environment}-grafana-eip"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# CloudWatch Alarms for Monitoring Infrastructure
resource "aws_cloudwatch_metric_alarm" "prometheus_cpu" {
  alarm_name          = "${var.environment}-prometheus-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors Prometheus instance CPU utilization"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  
  dimensions = {
    InstanceId = aws_instance.prometheus.id
  }
}

resource "aws_cloudwatch_metric_alarm" "prometheus_disk" {
  alarm_name          = "${var.environment}-prometheus-low-disk"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "disk_free"
  namespace           = "CWAgent"
  period              = "300"
  statistic           = "Average"
  threshold           = "15"  # 15% free space
  alarm_description   = "This metric monitors Prometheus disk space"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  
  dimensions = {
    InstanceId = aws_instance.prometheus.id
    path       = "/"
  }
}

# SNS Topic for Alerts
resource "aws_sns_topic" "alerts" {
  name = "${var.environment}-monitoring-alerts"
  
  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "dbre-team@company.com"
}

# S3 Bucket for Backup Storage
resource "aws_s3_bucket" "backups" {
  bucket = "betting-backups-${var.environment}"
  
  tags = {
    Name        = "PostgreSQL Backups"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  
  rule {
    id     = "daily-backups-lifecycle"
    status = "Enabled"
    
    transition {
      days          = 30
      storage_class = "GLACIER"
    }
    
    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# IAM Role for EC2 Instances (for S3 backup access)
resource "aws_iam_role" "monitoring" {
  name = "${var.environment}-monitoring-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy" "monitoring_s3" {
  name = "${var.environment}-monitoring-s3-policy"
  role = aws_iam_role.monitoring.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.environment}-monitoring-profile"
  role = aws_iam_role.monitoring.name
}

# Outputs
output "prometheus_url" {
  description = "Prometheus web UI URL"
  value       = "http://${aws_instance.prometheus.private_ip}:9090"
}

output "grafana_url" {
  description = "Grafana web UI URL"
  value       = "http://${aws_eip.grafana.public_ip}:3000"
}

output "backup_bucket" {
  description = "S3 bucket for backups"
  value       = aws_s3_bucket.backups.bucket
}

output "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  value       = aws_sns_topic.alerts.arn
}


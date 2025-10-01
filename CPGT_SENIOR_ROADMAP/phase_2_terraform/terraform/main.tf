
# main.tf
locals {
  # e.g., "phase-2-tf-ec2-dev"
  name = "${var.project_name}-${var.env}"

  tags = {
    Project = var.project_name
    Env     = var.env
    Owner   = "bernie"
  }
}############################################
# VPC  (create + enable DNS hostnames)
############################################
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-${var.env}-vpc"
    Project = var.project_name
    Env     = var.env
  }
}

############################################
# Public Subnet
############################################
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-${var.env}-pub-a"
    Project = var.project_name
    Env     = var.env
  }
}

############################################
# Internet Gateway + attach to VPC
############################################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name    = "${var.project_name}-${var.env}-igw"
    Project = var.project_name
    Env     = var.env
  }
}

############################################
# Route Table (public) + default route via IGW
############################################
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name    = "${var.project_name}-${var.env}-rt-public"
    Project = var.project_name
    Env     = var.env
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

############################################
# Security Group (SSH + HTTP)
############################################
resource "aws_security_group" "pub_sg" {
  name        = "${var.project_name}-${var.env}-pub-sg"
  description = "PUB SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]  # tighten to "x.x.x.x/32"
  }

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-pub-sg"
    Project = var.project_name
    Env     = var.env
  }
}

############################################
# AMI (Amazon Linux 2023 x86_64)
############################################
# SSM parameter -> AL2023 AMI ID (x86_64, kernel 6.1)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}


############################################
# EC2 instance in the public subnet
############################################
resource "aws_instance" "web" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.pub_sg.id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y nginx
    systemctl enable --now nginx
    echo "Hello from Terraform!" > /usr/share/nginx/html/index.html
  EOF

  tags = {
    Name    = "${var.project_name}-${var.env}-web"
    Project = var.project_name
    Env     = var.env
  }
}

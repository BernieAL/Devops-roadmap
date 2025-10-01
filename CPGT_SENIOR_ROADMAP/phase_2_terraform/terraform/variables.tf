variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "terraform_deployer"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "key_name" {
  description = "Name of existing AWS key pair to SSH into EC2"
  type        = string
  default     = "bootcamp-key"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "my_ip_cidr" {
  description = "CIDR range allowed to SSH (restrict to your IP in real use)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "env" {
  description = "Environment suffix (dev/stage/prod)"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project identifier used in tags and resource names"
  type        = string
  default     = "phase-2-tf-ec2"
}

# --- Core network IDs ---
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Public subnet ID"
  value       = aws_subnet.public.id
}

output "route_table_id" {
  description = "Public route table ID"
  value       = aws_route_table.public.id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.igw.id
}

output "security_group_id" {
  description = "Security Group ID for the web instance"
  value       = aws_security_group.pub_sg.id
}

# --- Instance details ---
output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.web.id
}

output "public_ip" {
  description = "EC2 public IP address"
  value       = aws_instance.web.public_ip
}

# Handy URLs/commands
output "http_url" {
  description = "HTTP URL for quick test"
  value       = "http://${aws_instance.web.public_ip}"
}

# Render a ready-to-copy SSH command (adjust user if you use Ubuntu)
output "ssh_command" {
  description = "SSH command with your key (Amazon Linux user is ec2-user)"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.web.public_ip}"
}

# Which AMI did 'latest' resolve to?
output "resolved_ami_id" {
  description = "Resolved AMI ID from SSM 'latest' parameter"
  value       = data.aws_ssm_parameter.al2023.value
  sensitive = true
}

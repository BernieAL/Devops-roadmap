#!/usr/bin/env bash
set -euo pipefail

# ---- VARS ----
REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
PUB_CIDR="10.0.1.0/24"
KEY_NAME="bootcamp-key"          # AWS key pair NAME (no slashes)
SG_NAME="pub-sg"

# ---- Key pair (AWS name vs local file path) ----
LOCAL_KEY_PATH="$HOME/.ssh/${KEY_NAME}.pem"
mkdir -p "$HOME/.ssh"

if ! aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
  echo "Creating key pair $KEY_NAME ..."
  aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text > "$LOCAL_KEY_PATH"
  chmod 600 "$LOCAL_KEY_PATH"
else
  echo "Key pair $KEY_NAME already exists in AWS."
  if [[ ! -f "$LOCAL_KEY_PATH" ]]; then
    echo "WARNING: Local private key $LOCAL_KEY_PATH not found."
    echo "Create/import a NEW key pair and launch with it, or use SSM."
  fi
fi

# ---- Latest Amazon Linux 2 (kernel 5.10) AMI ----
AMI_AL2=$(aws ec2 describe-images --region "$REGION" --owners "amazon" \
  --filters "Name=name,Values=amzn2-ami-kernel-5.10-hvm-*-x86_64-gp2" "Name=state,Values=available" \
  --query 'Images|sort_by(@,&CreationDate)[-1].ImageId' --output text)
echo "Using AMI: $AMI_AL2"

# ---- VPC + Subnet ----
VPC_ID=$(aws ec2 create-vpc --region "$REGION" --cidr-block "$VPC_CIDR" \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=bootcamp-vpc}]' \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support

PUB_SUBNET_ID=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" \
  --cidr-block "$PUB_CIDR" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=bootcamp-public-subnet}]' \
  --query 'Subnet.SubnetId' --output text)

# Auto-assign public IPs in public subnet
aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$PUB_SUBNET_ID" --map-public-ip-on-launch

# ---- IGW + Route Table ----
IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=bootcamp-igw}]' \
  --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --region "$REGION" --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

RT_ID=$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=bootcamp-public-rt}]' \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --region "$REGION" --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID"

aws ec2 associate-route-table --region "$REGION" --route-table-id "$RT_ID" --subnet-id "$PUB_SUBNET_ID"

# ---- Security Group (SSH from your IP) ----
PUB_SG_ID=$(aws ec2 create-security-group --region "$REGION" --group-name "$SG_NAME" \
  --description "Public SSH access" --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)

MYIP="$(curl -s https://checkip.amazonaws.com)/32"
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$PUB_SG_ID" \
  --protocol tcp --port 22 --cidr "$MYIP"

aws ec2 create-tags --region "$REGION" --resources "$PUB_SG_ID" \
  --tags Key=Name,Value=bootcamp-pub-sg

# ---- Launch EC2 ----
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_AL2" --instance-type t2.micro \
  --key-name "$KEY_NAME" \
  --subnet-id "$PUB_SUBNET_ID" \
  --security-group-ids "$PUB_SG_ID" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bootcamp-ec2}]' \
  --query 'Instances[0].InstanceId' --output text)

echo "Launched instance: $INSTANCE_ID"

aws ec2 wait instance-running   --region "$REGION" --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$INSTANCE_ID"

PUB_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "EC2 public IP: $PUB_IP"

aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Priv:PrivateIpAddress,Pub:PublicIpAddress,State:State.Name,Subnet:SubnetId}' \
  --output table

echo
echo "SSH with:"
echo "  ssh -i ${LOCAL_KEY_PATH} ec2-user@${PUB_IP}"



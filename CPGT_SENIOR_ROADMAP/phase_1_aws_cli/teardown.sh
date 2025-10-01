
#commands.sh order -> vpc,subnet,igw route table, sec group, launch instance 
#reversed order to build order in commands.sh


#!/usr/bin/env bash
set -euo pipefail


REGION="${REGION:-us-east-1}"


echo "Fetching resource IDs…"

# Get instance ID(s)
INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=bootcamp-day1" "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)



if [[ -n "$INSTANCE_IDS" ]]; then
    echo "Terminating EC2 isntances: $INSTANCE_IDS"
     aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS
fi

# Get security group IDs (exclude default)
SG_IDS=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=group-name,Values=bootcamp-ssh-only" \
  --query "SecurityGroups[].GroupId" \
  --output text)

if [[ -n "$SG_IDS" ]]; then
  echo "Deleting security groups: $SG_IDS"
  for sg in $SG_IDS; do
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg"
  done
fi

# Get IGW
IGW_ID=$(aws ec2 describe-internet-gateways \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=bootcamp-day1" \
  --query "InternetGateways[].InternetGatewayId" \
  --output text)

if [[ -n "$IGW_ID" ]]; then
  VPC_ID=$(aws ec2 describe-internet-gateways \
    --region "$REGION" \
    --internet-gateway-ids "$IGW_ID" \
    --query "InternetGateways[].Attachments[].VpcId" \
    --output text)
  echo "Detaching and deleting IGW: $IGW_ID"
  aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID"
fi

# Get route tables (non-main)
RTB_IDS=$(aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=bootcamp-day1" \
  --query "RouteTables[].RouteTableId" \
  --output text)

if [[ -n "$RTB_IDS" ]]; then
  echo "Deleting route tables: $RTB_IDS"
  for rtb in $RTB_IDS; do
    aws ec2 delete-route-table --region "$REGION" --route-table-id "$rtb"
  done
fi

# Get subnets
SUBNET_IDS=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=bootcamp-day1" \
  --query "Subnets[].SubnetId" \
  --output text)

if [[ -n "$SUBNET_IDS" ]]; then
  echo "Deleting subnets: $SUBNET_IDS"
  for sn in $SUBNET_IDS; do
    aws ec2 delete-subnet --region "$REGION" --subnet-id "$sn"
  done
fi

# Get VPC
VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=bootcamp-day1" \
  --query "Vpcs[].VpcId" \
  --output text)

if [[ -n "$VPC_ID" ]]; then
  echo "Deleting VPC: $VPC_ID"
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
fi

echo "Teardown complete ✅"
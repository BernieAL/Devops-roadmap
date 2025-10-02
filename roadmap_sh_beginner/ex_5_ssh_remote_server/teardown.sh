REGION=us-east-1

# 1) Terminate instances tagged Name=bootcamp-ec2
aws ec2 describe-instances --region $REGION \
  --filters "Name=tag:Name,Values=bootcamp-ec2" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text |
xargs -r aws ec2 terminate-instances --region $REGION --instance-ids

aws ec2 wait instance-terminated --region $REGION --instance-ids $(aws ec2 describe-instances --region $REGION \
  --filters "Name=tag:Name,Values=bootcamp-ec2" --query 'Reservations[].Instances[].InstanceId' --output text)

# 2) Find VPC
VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters "Name=tag:Name,Values=bootcamp-vpc" --query 'Vpcs[0].VpcId' --output text)

# 3) Disassociate & delete custom route tables (Name=bootcamp-public-rt)
RT_ID=$(aws ec2 describe-route-tables --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=bootcamp-public-rt" --query 'RouteTables[0].RouteTableId' --output text)
if [ "$RT_ID" != "None" ]; then
  # Disassociate non-main associations
  aws ec2 describe-route-tables --region $REGION --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text |
  xargs -r -n1 aws ec2 disassociate-route-table --region $REGION --association-id
  aws ec2 delete-route-table --region $REGION --route-table-id "$RT_ID" || true
fi

# 4) Detach & delete IGW
IGW_ID=$(aws ec2 describe-internet-gateways --region $REGION --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text)
if [ "$IGW_ID" != "None" ]; then
  aws ec2 detach-internet-gateway --region $REGION --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" || true
  aws ec2 delete-internet-gateway --region $REGION --internet-gateway-id "$IGW_ID" || true
fi

# 5) Delete subnet (Name=bootcamp-public-subnet)
SUBNET_ID=$(aws ec2 describe-subnets --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=bootcamp-public-subnet" --query 'Subnets[0].SubnetId' --output text)
[ "$SUBNET_ID" != "None" ] && aws ec2 delete-subnet --region $REGION --subnet-id "$SUBNET_ID" || true

# 6) Delete security group (group-name=pub-sg in that VPC)
SG_ID=$(aws ec2 describe-security-groups --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=pub-sg" --query 'SecurityGroups[0].GroupId' --output text)
[ "$SG_ID" != "None" ] && aws ec2 delete-security-group --region $REGION --group-id "$SG_ID" || true

# 7) Delete VPC
[ "$VPC_ID" != "None" ] && aws ec2 delete-vpc --region $REGION --vpc-id "$VPC_ID" || true

# 8) (Optional) Delete the correct key pair (by NAME)
# aws ec2 delete-key-pair --region $REGION --key-name bootcamp-key
# rm -f "$HOME/.ssh/bootcamp-key.pem"


../../full_teardown.sh $VPC_ID
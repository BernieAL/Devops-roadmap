
# Vars (adjust as needed)
REGION=us-east-1
VPC_CIDR=10.0.0.0/16 #how many bits reserved for network? how much left for hosts?
PUB_CIDR=10.0.1.0/24 #we want subnet to be smaller 
KEY_NAME=bootcamp-key
AMI_AL2=$(aws ec2 describe-images --region $REGION --owners "amazon" \
  --filters "Name=name,Values=amzn2-ami-kernel-5.10-hvm-*-x86_64-gp2" "Name=state,Values=available" \
  --query 'Images|sort_by(@,&CreationDate)[-1].ImageId' --output text)


#launch vpc, subnet,igw, route table

#VPC
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --query 'Vpc.VpcId' \
    --output text \
    --region $REGION)

aws ec2 modify-vpc-attribute \
    --vpc-id $VPC_ID \ 
    --enable-dns-hostnames \ 
    --region $REGION \

#subnet
PUB_SUBNET_ID=$(aws ec2 create-subnet 
    --vpc-id $VPC_ID \
    --cidr-block $PUB_CIDR \ 
    --query 'Subnet.SubnetId' \
    --output text \
    --region $REGION)

#IGW
IGW_ID=$(aws ec2 create-internet-gateway 
    --query 'InternetGateway.InternetGatewayId' 
    --output text --region $REGION)

aws ec2 attach-internet-gateway 
    --internet-gateway-id $IGW_ID 
    --vpc-id $VPC_ID 
    --region $REGION

#route table
PUB_RT_ID=$(aws ec2 create-route-table  \
    --vpc-id $VPC_ID \
    --query 'RouteTable.RouteTableId' \
    --output text --region $REGION) 

aws ec2 create-route \
    --route-table-id $PUB_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID \
    --region $REGION \

aws ec2 associate-route-table \
    --route-table-id $PUB_RT_ID \ 
    --subnet-id $PUB_SUBNET_ID  \
    --region $REGION \

#sec group
PUB_SG_ID=$(aws ec2 create-security-group \
    --group-name pub-sg
    --description "PUB SSH" \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text \
    --region $REGION)

#launch ec2 instance inside of it
EC2_ID=$(aws ec2 run-instances \
    --image-id $AMI_AL2 \
    --instance-type t2.micro \
    --key-name $KEY_NAME \
    --subnet-id $PUB_SUBNET_ID \
    --security-group-ids $PUB_SG_ID \
    --query 'Instances[0].InstanceId' \
    --output text --region $REGION)



#### MONITORING SECTION

#create SNS topic - for email notifications, will be used by CloudWatch Alarm
SNS_TOPIC_ARN=$( aws sns create-topic \
    --name bootcamp - alerts \
    --query 'TopicArn' \
    --output text)

#Subscribe recipient email to recieve alerts
aws sns subscribe \
    --topic-arn $SNS_TOPIC_ARN \
    --protocol email \
    --notification-endpoint "balmanzar883@gmail.com"

    echo "check your email to confirm SNS subscription:"

#Create Alarm, attach SNS TOPIC, and instance

aws cloudwatch put-metric-alarm \
		  --alarm-name "EC2-HealthCheck-$INSTANCE_ID" \
		  --alarm-description "Alert if EC2 fails status checks" \
		  --metric-name StatusCheckFailed \    #THiS IS THE METRIC SELECTED
		  --namespace AWS/EC2 \
		  --statistic Maximum \
		  --period 60 \
		  --threshold 1 \
		  --comparison-operator GreaterThanOrEqualToThreshold \
		  --dimensions Name=InstanceId,Value=$INSTANCE_ID \
		  --evaluation-periods 2 \
		  --alarm-actions $SNS_TOPIC_ARN

	aws cloudwatch describe-alarms \
  --alarm-names "EC2-HealthCheck-$INSTANCE_ID" \aws cloudwatch delete-alarms --alarm-names "EC2-HealthCheck-$INSTANCE_ID"
aws sns delete-topic --topic-arn $SNS_TOPIC_ARN

  --query "MetricAlarms[].StateValue"
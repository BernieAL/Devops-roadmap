# --- QUICK BLOCKER SCAN FOR VPC DELETION ---
VPC_ID="vpc-06dafe8d952e11a57"
REGION="us-east-1"   # <--- change if needed
R="--region $REGION"

echo -e "\n[1/12] ENIs (these usually reveal the culprit):"
aws ec2 describe-network-interfaces $R --filters Name=vpc-id,Values=$VPC_ID \
  --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status,IfType:InterfaceType,Desc:Description,Owner:OwnerId,Requester:RequesterId,AttInst:Attachment.InstanceId,Subnet:SubnetId}" \
  --output table

echo -e "\n[2/12] VPC Endpoints (Gateway & Interface):"
aws ec2 describe-vpc-endpoints $R --filters Name=vpc-id,Values=$VPC_ID \
  --query "VpcEndpoints[].{Id:VpcEndpointId,Service:ServiceName,Type:VpcEndpointType,State:State,Subnets:SubnetIds}" --output table

echo -e "\n[3/12] Route53 Resolver Endpoints:"
aws route53resolver list-resolver-endpoints $R \
  --query "ResolverEndpoints[?VpcId=='$VPC_ID'].[Id,Name,Direction,IpAddressCount,Status]" --output table

echo -e "\n[4/12] EC2 Instance Connect Endpoints:"
aws ec2 describe-instance-connect-endpoints $R --filters Name=vpc-id,Values=$VPC_ID \
  --query "InstanceConnectEndpoints[].{Id:InstanceConnectEndpointId,State:State,Subnets:SubnetId}" --output table

echo -e "\n[5/12] Flow Logs (fixed flag: --filter):"
aws ec2 describe-flow-logs $R --filter Name=resource-id,Values=$VPC_ID \
  --query "FlowLogs[].{Id:FlowLogId,Dest:LogDestination,Status:FlowLogStatus}" --output table

echo -e "\n[6/12] NAT GWs still around?"
aws ec2 describe-nat-gateways $R --filter Name=vpc-id,Values=$VPC_ID \
  --query "NatGateways[].{Id:NatGatewayId,State:State,Subnets:SubnetId}" --output table

echo -e "\n[7/12] Internet GWs & Egress-only IGWs:"
aws ec2 describe-internet-gateways $R --filters Name=attachment.vpc-id,Values=$VPC_ID \
  --query "InternetGateways[].{Id:InternetGatewayId,Attach:Attachments}" --output table
aws ec2 describe-egress-only-internet-gateways $R \
  --query "EgressOnlyInternetGateways[?Attachments[?VpcId=='$VPC_ID']].[EgressOnlyInternetGatewayId]" --output table

echo -e "\n[8/12] Route Tables (any non-main left with associations?):"
aws ec2 describe-route-tables $R --filters Name=vpc-id,Values=$VPC_ID \
  --query "RouteTables[].{Id:RouteTableId,Main:Associations[?Main==\`true\`]|[0].Main,Assoc:Associations[].RouteTableAssociationId,Routes:Routes[].GatewayId}" \
  --output table

echo -e "\n[9/12] Subnets (should be none if you’re about to delete the VPC):"
aws ec2 describe-subnets $R --filters Name=vpc-id,Values=$VPC_ID \
  --query "Subnets[].{Id:SubnetId,Az:AvailabilityZone}" --output table

echo -e "\n[10/12] VPN / TGW attachments:"
aws ec2 describe-vpn-gateways $R --filters Name=attachments.vpc-id,Values=$VPC_ID \
  --query "VpnGateways[].{Id:VpnGatewayId,State:State}" --output table
aws ec2 describe-transit-gateway-attachments $R --filters Name=resource-type,Values=vpc Name=resource-id,Values=$VPC_ID \
  --query "TransitGatewayAttachments[].{Id:TransitGatewayAttachmentId,State:State}" --output table

echo -e "\n[11/12] RDS / EFS / EKS / ElastiCache / OpenSearch / MSK / FSx / Redshift / Directory Service:"
aws rds describe-db-instances $R --query "DBInstances[?DBSubnetGroup.VpcId=='$VPC_ID'].[DBInstanceIdentifier,DBInstanceStatus]" --output table
aws rds describe-db-subnet-groups $R --query "DBSubnetGroups[?VpcId=='$VPC_ID'].[DBSubnetGroupName]" --output table
SUBNETS=$(aws ec2 describe-subnets $R --filters Name=vpc-id,Values=$VPC_ID --query "Subnets[].SubnetId" --output text)
for fs in $(aws efs describe-file-systems $R --query "FileSystems[].FileSystemId" --output text 2>/dev/null); do
  mts=$(aws efs describe-mount-targets $R --file-system-id "$fs" --query "MountTargets[].{Id:MountTargetId,SN:SubnetId}" --output text 2>/dev/null || true)
  if [[ -n "$mts" ]]; then
    while read -r mt mt_subnet; do
      [[ " $SUBNETS " == *" $mt_subnet "* ]] && echo "EFS $fs has mount target $mt in subnet $mt_subnet"
    done <<< "$mts"
  fi
done
for c in $(aws eks list-clusters $R --query "clusters[]" --output text 2>/dev/null || true); do
  v=$(aws eks describe-cluster $R --name "$c" --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null || true)
  [[ "$v" == "$VPC_ID" ]] && echo "EKS cluster in VPC: $c"
done
aws elasticache describe-cache-subnet-groups $R --query "CacheSubnetGroups[?VpcId=='$VPC_ID'].[CacheSubnetGroupName]" --output table 2>/dev/null || true
for d in $(aws opensearch list-domain-names $R --query "DomainNames[].DomainName" --output text 2>/dev/null || true); do
  v=$(aws opensearch describe-domain $R --domain-name "$d" --query "DomainStatus.VPCOptions.VPCId" --output text 2>/dev/null || true)
  [[ "$v" == "$VPC_ID" ]] && echo "OpenSearch domain: $d"
done
aws kafka list-clusters-v2 $R --query "ClusterInfoList[].{Name:ClusterName,Vpc:VpcConfig.VpcId,State:State}" --output table 2>/dev/null | grep "$VPC_ID" || true
aws fsx describe-file-systems $R --query "FileSystems[].{Id:FileSystemId,Subnets:SubnetIds}" --output table 2>/dev/null || true
aws redshift describe-clusters $R --query "Clusters[?VpcId=='$VPC_ID'].[ClusterIdentifier,ClusterStatus]" --output table 2>/dev/null || true
aws ds describe-directories $R --query "DirectoryDescriptions[?VpcSettings.VpcId=='$VPC_ID'].[DirectoryId,Name,Stage]" --output table 2>/dev/null || true

echo -e "\n[12/12] Last-resort: any ENIs left (re-list after everything above):"
aws ec2 describe-network-interfaces $R --filters Name=vpc-id,Values=$VPC_ID \
  --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status,Desc:Description,IfType:InterfaceType,Owner:OwnerId,Requester:RequesterId,AttInst:Attachment.InstanceId}" \
  --output table

# 1) Remove default routes from the non-main RTB (IPv4 & IPv6 just in case)
aws ec2 delete-route $R --route-table-id "$RTB_ID" --destination-cidr-block 0.0.0.0/0 || true
aws ec2 delete-route $R --route-table-id "$RTB_ID" --destination-ipv6-cidr-block ::/0 || true

# 2) Delete the non-main RTB
aws ec2 delete-route-table $R --route-table-id "$RTB_ID"

# 3) Detach and delete the IGW
aws ec2 detach-internet-gateway $R --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" || true
aws ec2 delete-internet-gateway $R --internet-gateway-id "$IGW_ID"

# (Optional) If you had an egress-only IGW, nuke it too:
# aws ec2 describe-egress-only-internet-gateways $R \
#   --query "EgressOnlyInternetGateways[?Attachments[?VpcId=='$VPC_ID']].[EgressOnlyInternetGatewayId]" --output text
# aws ec2 delete-egress-only-internet-gateway $R --egress-only-internet-gateway-id <eigw-...>

# 4) Try deleting the VPC again
aws ec2 delete-vpc $R --vpc-id "$VPC_ID"
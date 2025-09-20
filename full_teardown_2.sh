#!/usr/bin/env bash
# Fully tears down a VPC and everything inside it (lab-safe).
# Usage: ./teardown_full.sh <VPC_ID> [--key <KEY_NAME>] [--region <AWS_REGION>] [--dry-run]

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <VPC_ID> [--key <KEY_NAME>] [--region <AWS_REGION>] [--dry-run]"
  exit 1
fi

VPC_ID="$1"; shift || true
KEY_NAME=""
REGION_FLAG=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY_NAME="$2"; shift 2 ;;
    --region) REGION_FLAG="--region $2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    *) echo "Unknown arg: $1" ; exit 1 ;;
  esac
done

run() {
  local cmd="$*"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $cmd"
  else
    eval "$cmd"
  fi
}

log() { echo -e "\n==> $*"; }

log "Starting FULL teardown for VPC: $VPC_ID"
[[ -n "$KEY_NAME" ]] && echo "Will also delete key pair: $KEY_NAME"
[[ -n "$REGION_FLAG" ]] && echo "Region override: $REGION_FLAG"
[[ "$DRY_RUN" == "true" ]] && echo "DRY RUN MODE (nothing will be deleted)"

# Sanity
VPC_CHECK=$(aws ec2 describe-vpcs $REGION_FLAG --vpc-ids "$VPC_ID" --query "Vpcs[].VpcId" --output text 2>/dev/null || true)
if [[ -z "$VPC_CHECK" ]]; then
  echo "VPC $VPC_ID not found. Exiting."
  exit 0
fi

wait_nat_deleted() {
  local nat_id="$1"
  echo "Waiting for NAT Gateway $nat_id to delete..."
  for _ in {1..60}; do
    STATE=$(aws ec2 describe-nat-gateways $REGION_FLAG --nat-gateway-ids "$nat_id" --query "NatGateways[0].State" --output text 2>/dev/null || true)
    [[ "$STATE" == "deleted" || -z "$STATE" ]] && { echo "NAT $nat_id deleted."; return 0; }
    sleep 10
  done
  echo "Timeout waiting for NAT $nat_id; continuing."
}

# 1) Instances
log "Terminate EC2 instances"
INSTANCE_IDS=$(aws ec2 describe-instances $REGION_FLAG \
  --filters "Name=network-interface.vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text | tr -s ' ' || true)
if [[ -n "${INSTANCE_IDS:-}" ]]; then
  echo "Terminating: $INSTANCE_IDS"
  run aws ec2 terminate-instances $REGION_FLAG --instance-ids $INSTANCE_IDS
  [[ "$DRY_RUN" == "false" ]] && aws ec2 wait instance-terminated $REGION_FLAG --instance-ids $INSTANCE_IDS || true
else
  echo "No instances found."
fi

# 2) Auto Scaling groups referencing subnets in this VPC (best-effort)
log "Delete Auto Scaling groups (best-effort)"
ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups $REGION_FLAG \
  --query "AutoScalingGroups[?contains(VPCZoneIdentifier, \`$VPC_ID\` )].AutoScalingGroupName" --output text 2>/dev/null || true)
if [[ -n "${ASG_NAMES:-}" ]]; then
  for asg in $ASG_NAMES; do
    echo "Deleting ASG: $asg (force-delete)"
    run aws autoscaling delete-auto-scaling-group $REGION_FLAG --auto-scaling-group-name "$asg" --force-delete || true
  done
else
  echo "No ASGs tied to this VPC (or none detected)."
fi

# 3) Load Balancers v2 (ALB/NLB) + Target Groups
log "Delete ALB/NLB and Target Groups"
LB_ARNS=$(aws elbv2 describe-load-balancers $REGION_FLAG \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null | tr -s ' ' || true)
if [[ -n "${LB_ARNS:-}" ]]; then
  for lb in $LB_ARNS; do
    echo "Deleting LBv2: $lb"
    run aws elbv2 delete-load-balancer $REGION_FLAG --load-balancer-arn "$lb"
  done
  TG_ARNS=$(aws elbv2 describe-target-groups $REGION_FLAG \
    --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null | tr -s ' ' || true)
  if [[ -n "${TG_ARNS:-}" ]]; then
    for tg in $TG_ARNS; do
      echo "Deleting Target Group: $tg"
      run aws elbv2 delete-target-group $REGION_FLAG --target-group-arn "$tg"
    done
  fi
else
  echo "No ALB/NLB found."
fi

# 4) Classic ELBs (v1)
log "Delete classic ELBs (v1)"
ELB_NAMES=$(aws elb describe-load-balancers $REGION_FLAG \
  --query "LoadBalancerDescriptions[?contains(VPCId, \`$VPC_ID\`)].LoadBalancerName" --output text 2>/dev/null | tr -s ' ' || true)
if [[ -n "${ELB_NAMES:-}" ]]; then
  for elb in $ELB_NAMES; do
    echo "Deleting ELBv1: $elb"
    run aws elb delete-load-balancer $REGION_FLAG --load-balancer-name "$elb"
  done
else
  echo "No classic ELBs found."
fi

# 5) NAT GWs + EIPs
log "Delete NAT Gateways and release EIPs"
NAT_IDS=$(aws ec2 describe-nat-gateways $REGION_FLAG --filter "Name=vpc-id,Values=$VPC_ID" \
  --query "NatGateways[].NatGatewayId" --output text 2>/dev/null | tr -s ' ' || true)
if [[ -n "${NAT_IDS:-}" ]]; then
  for nat in $NAT_IDS; do
    ALLOC_IDS=$(aws ec2 describe-nat-gateways $REGION_FLAG --nat-gateway-ids "$nat" \
      --query "NatGateways[0].NatGatewayAddresses[].AllocationId" --output text | tr -s ' ' || true)
    echo "Deleting NAT GW: $nat"
    run aws ec2 delete-nat-gateway $REGION_FLAG --nat-gateway-id "$nat"
    [[ "$DRY_RUN" == "false" ]] && wait_nat_deleted "$nat"
    for alloc in $ALLOC_IDS; do
      echo "Releasing EIP allocation: $alloc"
      run aws ec2 release-address $REGION_FLAG --allocation-id "$alloc" || true
    done
  done
else
  echo "No NAT Gateways found."
fi

# 6) VPC Endpoints (Gateway & Interface) + Endpoint Services (best-effort)
log "Delete VPC Endpoints"
VPCE_IDS=$(aws ec2 describe-vpc-endpoints $REGION_FLAG --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null | tr -s ' ' || true)
if [[ -n "${VPCE_IDS:-}" ]]; then
  echo "Deleting VPC endpoints: $VPCE_IDS"
  run aws ec2 delete-vpc-endpoints $REGION_FLAG --vpc-endpoint-ids $VPCE_IDS || true
else
  echo "No VPC endpoints found."
fi

# 7) Flow Logs
log "Delete VPC Flow Logs"
FLOWLOG_IDS=$(aws ec2 describe-flow-logs $REGION_FLAG \
  --filters "Name=resource-id,Values=$VPC_ID" --query "FlowLogs[].FlowLogId" --output text 2>/dev/null | tr -s ' ' || true)
if [[ -n "${FLOWLOG_IDS:-}" ]]; then
  echo "Deleting flow logs: $FLOWLOG_IDS"
  run aws ec2 delete-flow-logs $REGION_FLAG --flow-log-ids $FLOWLOG_IDS || true
else
  echo "No flow logs found."
fi

# 8) EC2 Instance Connect Endpoints
log "Delete EC2 Instance Connect Endpoints"
EICE_IDS=$(aws ec2 describe-instance-connect-endpoints $REGION_FLAG \
  --filters "Name=vpc-id,Values=$VPC_ID" --query "InstanceConnectEndpoints[].InstanceConnectEndpointId" \
  --output text 2>/dev/null | tr -s ' ' || true)
if [[ -n "${EICE_IDS:-}" ]]; then
  for eice in $EICE_IDS; do
    echo "Deleting EICE: $eice"
    run aws ec2 delete-instance-connect-endpoint $REGION_FLAG --instance-connect-endpoint-id "$eice" || true
  done
else
  echo "No EICE found."
fi

# 9) Route53 Resolver Endpoints (inbound/outbound)
log "Delete Route53 Resolver endpoints"
RSLVR_IN=$(aws route53resolver list-resolver-endpoints $REGION_FLAG \
  --query "ResolverEndpoints[?VpcId=='$VPC_ID' && Direction=='INBOUND'].Id" --output text 2>/dev/null | tr -s ' ' || true)
RSLVR_OUT=$(aws route53resolver list-resolver-endpoints $REGION_FLAG \
  --query "ResolverEndpoints[?VpcId=='$VPC_ID' && Direction=='OUTBOUND'].Id" --output text 2>/dev/null | tr -s ' ' || true)
for rid in $RSLVR_IN $RSLVR_OUT; do
  echo "Deleting Resolver endpoint: $rid"
  run aws route53resolver delete-resolver-endpoint $REGION_FLAG --resolver-endpoint-id "$rid" || true
done

# 10) VPN Gateways + detach, Customer Gateways (best-effort), TGW attachments
log "Delete/Detach VPN & Transit Gateway attachments"
VGW_IDS=$(aws ec2 describe-vpn-gateways $REGION_FLAG --filters "Name=attachments.vpc-id,Values=$VPC_ID" \
  --query "VpnGateways[].VpnGatewayId" --output text 2>/dev/null | tr -s ' ' || true)
for vgw in $VGW_IDS; do
  echo "Detaching & deleting VGW: $vgw"
  run aws ec2 detach-vpn-gateway $REGION_FLAG --vpn-gateway-id "$vgw" --vpc-id "$VPC_ID" || true
  run aws ec2 delete-vpn-gateway $REGION_FLAG --vpn-gateway-id "$vgw" || true
done
# Transit Gateway attachments
TGW_ATTACH_IDS=$(aws ec2 describe-transit-gateway-attachments $REGION_FLAG \
  --filters "Name=resource-type,Values=vpc" "Name=resource-id,Values=$VPC_ID" \
  --query "TransitGatewayAttachments[].TransitGatewayAttachmentId" --output text 2>/dev/null | tr -s ' ' || true)
for tga in $TGW_ATTACH_IDS; do
  echo "Deleting TGW attachment: $tga"
  run aws ec2 delete-transit-gateway-attachment $REGION_FLAG --transit-gateway-attachment-id "$tga" || true
done

# 11) Detach & delete IGWs + egress-only IGWs (IPv6)
log "Detach & delete IGWs"
IGW_IDS=$(aws ec2 describe-internet-gateways $REGION_FLAG --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[].InternetGatewayId" --output text 2>/dev/null | tr -s ' ' || true)
for igw in $IGW_IDS; do
  echo "Detaching IGW: $igw"
  run aws ec2 detach-internet-gateway $REGION_FLAG --internet-gateway-id "$igw" --vpc-id "$VPC_ID" || true
  echo "Deleting IGW: $igw"
  run aws ec2 delete-internet-gateway $REGION_FLAG --internet-gateway-id "$igw" || true
done
log "Delete egress-only IGWs (IPv6)"
EOIGW_IDS=$(aws ec2 describe-egress-only-internet-gateways $REGION_FLAG --query "EgressOnlyInternetGateways[?Attachments[?VpcId=='$VPC_ID']].EgressOnlyInternetGatewayId" \
  --output text 2>/dev/null | tr -s ' ' || true)
for eo in $EOIGW_IDS; do
  echo "Deleting egress-only IGW: $eo"
  run aws ec2 delete-egress-only-internet-gateway $REGION_FLAG --egress-only-internet-gateway-id "$eo" || true
done

# 12) Route tables (non-main)
log "Delete non-main route tables"
RTB_IDS=$(aws ec2 describe-route-tables $REGION_FLAG --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[?Associations[?Main!=\`true\`]].RouteTableId" --output text 2>/dev/null | tr -s ' ' || true)
for rtb in $RTB_IDS; do
  ASSOCS=$(aws ec2 describe-route-tables $REGION_FLAG --route-table-ids "$rtb" \
    --query "RouteTables[0].Associations[?AssociationState.State=='associated'].RouteTableAssociationId" \
    --output text | tr -s ' ' || true)
  for assoc in $ASSOCS; do
    echo "Disassociating RTB assoc: $assoc"
    run aws ec2 disassociate-route-table $REGION_FLAG --association-id "$assoc" || true
  done
  echo "Deleting default route in $rtb (if any)"
  run aws ec2 delete-route $REGION_FLAG --route-table-id "$rtb" --destination-cidr-block 0.0.0.0/0 || true
  run aws ec2 delete-route $REGION_FLAG --route-table-id "$rtb" --destination-ipv6-cidr-block ::/0 || true
  echo "Deleting RTB: $rtb"
  run aws ec2 delete-route-table $REGION_FLAG --route-table-id "$rtb" || true
done

# 13) NACLs (non-default)
log "Delete non-default NACLs"
NACL_IDS=$(aws ec2 describe-network-acls $REGION_FLAG --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "NetworkAcls[?IsDefault==\`false\`].NetworkAclId" --output text 2>/dev/null | tr -s ' ' || true)
for nacl in $NACL_IDS; do
  echo "Deleting NACL: $nacl"
  run aws ec2 delete-network-acl $REGION_FLAG --network-acl-id "$nacl" || true
done

# 14) Security Groups (non-default)
log "Delete non-default Security Groups"
SG_IDS=$(aws ec2 describe-security-groups $REGION_FLAG --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null | tr -s ' ' || true)
for sg in $SG_IDS; do
  echo "Deleting SG: $sg"
  run aws ec2 delete-security-group $REGION_FLAG --group-id "$sg" || true
done

# 15) Subnets
log "Delete subnets"
SUBNET_IDS=$(aws ec2 describe-subnets $REGION_FLAG --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[].SubnetId" --output text 2>/dev/null | tr -s ' ' || true)
for sn in $SUBNET_IDS; do
  echo "Deleting subnet: $sn"
  run aws ec2 delete-subnet $REGION_FLAG --subnet-id "$sn" || true
done

# 16) DHCP options
log "DHCP options"
DHCP_OPTS_ID=$(aws ec2 describe-vpcs $REGION_FLAG --vpc-ids "$VPC_ID" --query "Vpcs[0].DhcpOptionsId" --output text 2>/dev/null || true)
if [[ -n "$DHCP_OPTS_ID" && "$DHCP_OPTS_ID" != "default" ]]; then
  echo "Disassociating & deleting DHCP options: $DHCP_OPTS_ID"
  run aws ec2 associate-dhcp-options $REGION_FLAG --dhcp-options-id default --vpc-id "$VPC_ID" || true
  run aws ec2 delete-dhcp-options $REGION_FLAG --dhcp-options-id "$DHCP_OPTS_ID" || true
fi

# 17) VPC Peering
log "Delete VPC Peering connections"
PEER_IDS=$(aws ec2 describe-vpc-peering-connections $REGION_FLAG \
  --query "VpcPeeringConnections[?RequesterVpcInfo.VpcId=='$VPC_ID' || AccepterVpcInfo.VpcId=='$VPC_ID'].VpcPeeringConnectionId" \
  --output text 2>/dev/null | tr -s ' ' || true)
for pcx in $PEER_IDS; do
  echo "Deleting peering: $pcx"
  run aws ec2 delete-vpc-peering-connection $REGION_FLAG --vpc-peering-connection-id "$pcx" || true
done

# 18) Sweep unattached ENIs, and surface blockers
log "Sweep unattached ENIs"
ENI_IDS=$(aws ec2 describe-network-interfaces $REGION_FLAG --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null | tr -s ' ' || true)
for eni in $ENI_IDS; do
  STATUS=$(aws ec2 describe-network-interfaces $REGION_FLAG --network-interface-ids "$eni" --query "NetworkInterfaces[0].Status" --output text)
  ATTACH=$(aws ec2 describe-network-interfaces $REGION_FLAG --network-interface-ids "$eni" --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null || true)
  if [[ "$STATUS" == "available" && "$ATTACH" == "None" ]]; then
    echo "Deleting unattached ENI: $eni"
    run aws ec2 delete-network-interface $REGION_FLAG --network-interface-id "$eni" || true
  fi
done

# Show remaining ENIs (likely blockers)
REMAINING_ENIS=$(aws ec2 describe-network-interfaces $REGION_FLAG --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status,Owner:OwnerId,Desc:Description,IfType:InterfaceType,AttInst:Attachment.InstanceId,Svc:RequesterId}" \
  --output table 2>/dev/null || true)
if [[ -n "$REMAINING_ENIS" ]]; then
  echo "Remaining ENIs (may block VPC deletion):"
  echo "$REMAINING_ENIS"
fi

# 19) Finally, delete the VPC
log "Delete the VPC"
run aws ec2 delete-vpc $REGION_FLAG --vpc-id "$VPC_ID" || {
  echo "DeleteVpc failed. Likely remaining dependencies (above)."
  exit 1
}

# 20) Optional key pair cleanup
if [[ -n "$KEY_NAME" ]]; then
  log "Delete key pair: $KEY_NAME"
  run aws ec2 delete-key-pair $REGION_FLAG --key-name "$KEY_NAME" || true
fi

echo "✅ Full teardown complete."

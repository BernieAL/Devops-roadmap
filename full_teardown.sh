#!/usr/bin/env bash
# auto_prune_vpcs.sh
# Discover VPCs automatically (all regions or one) and delete non-default VPCs you (or AWS services) created.
# Default: PLAN mode (no deletions). Use --execute to actually delete.
# Usage examples:
#   ./auto_prune_vpcs.sh                          # plan, all regions, skip default VPCs, skip managed services
#   ./auto_prune_vpcs.sh --execute                # execute, all regions
#   ./auto_prune_vpcs.sh --region us-east-1       # plan, only us-east-1
#   ./auto_prune_vpcs.sh --execute --include-managed
#   ./auto_prune_vpcs.sh --execute --include-default-vpcs   # (danger) will also delete default VPCs

set -euo pipefail

EXECUTE=false
INCLUDE_MANAGED=false
INCLUDE_DEFAULT=false
REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --include-managed) INCLUDE_MANAGED=true; shift ;;
    --include-default-vpcs) INCLUDE_DEFAULT=true; shift ;;
    --region) REGION="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--execute] [--include-managed] [--include-default-vpcs] [--region <aws-region>]
Default: plan-only, all regions, skip managed services, skip default VPCs.
EOF
      exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

say(){ echo -e "$*"; }
log(){ say "\n==> $*"; }
run() {
  local cmd="$*"
  if $EXECUTE; then
    echo "[exec] $cmd"
    eval "$cmd"
  else
    echo "[plan] $cmd"
  fi
}

# Regions to process
get_regions(){
  if [[ -n "$REGION" ]]; then
    echo "$REGION"
  else
    aws ec2 describe-regions --query "Regions[].RegionName" --output text
  fi
}

# Waiters
wait_nat_deleted(){
  local region_flag="$1" nat="$2"
  say "Waiting for NAT $nat to delete..."
  for _ in {1..60}; do
    st=$(aws ec2 describe-nat-gateways $region_flag --nat-gateway-ids "$nat" --query "NatGateways[0].State" --output text 2>/dev/null || true)
    [[ "$st" == "deleted" || -z "$st" ]] && { say "NAT $nat deleted."; return 0; }
    sleep 10
  done
  say "Timeout waiting for NAT $nat; continuing."
}

# Per-VPC teardown
teardown_vpc(){
  local vpc_id="$1" region="$2"
  local R="--region $region"

  # helper for deleting default routes quietly
  safe_delroute() {
    local rtb="$1"; shift
    local dest_flag="$*"
    if $EXECUTE; then
      echo "[exec] aws ec2 delete-route $R --route-table-id $rtb $dest_flag"
      # suppress InvalidRoute.NotFound while surfacing anything else
      if ! aws ec2 delete-route $R --route-table-id "$rtb" $dest_flag 2> /tmp/delroute.err; then
        if grep -q "InvalidRoute.NotFound" /tmp/delroute.err; then
          echo "(no such route $dest_flag on $rtb — continuing)"
        else
          cat /tmp/delroute.err >&2
          return 1
        fi
      fi
    else
      echo "[plan] aws ec2 delete-route $R --route-table-id $rtb $dest_flag"
    fi
  }

  say "VPC: $vpc_id  (region: $region)"
  local is_default
  is_default=$(aws ec2 describe-vpcs $R --vpc-ids "$vpc_id" --query "Vpcs[0].IsDefault" --output text)
  say "  IsDefault: $is_default | Mode: $([[ $EXECUTE == true ]] && echo EXECUTE || echo PLAN) | Managed: $([[ $INCLUDE_MANAGED == true ]] && echo INCLUDED || echo SKIPPED)"

  if [[ "$is_default" == "True" && "$INCLUDE_DEFAULT" == false ]]; then
    say "  Skipping default VPC (use --include-default-vpcs to allow)."
    return
  fi

  # 1) EC2 Instances
  log "Terminate EC2 instances"
  local instances
  instances=$(aws ec2 describe-instances $R \
    --filters "Name=network-interface.vpc-id,Values=$vpc_id" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text | tr -s ' ' || true)
  if [[ -n "${instances:-}" ]]; then
    say "  Instances: $instances"
    run aws ec2 terminate-instances $R --instance-ids $instances
    $EXECUTE && aws ec2 wait instance-terminated $R --instance-ids $instances || true
  else
    say "  No instances."
  fi

  # 2) Auto Scaling Groups (best-effort)
  log "Delete Auto Scaling Groups (best-effort)"
  local asgs
  asgs=$(aws autoscaling describe-auto-scaling-groups $R \
    --query "AutoScalingGroups[?contains(VPCZoneIdentifier, \`$vpc_id\`)].AutoScalingGroupName" --output text 2>/dev/null | tr -s ' ' || true)
  for asg in $asgs; do
    say "  ASG: $asg"
    run aws autoscaling delete-auto-scaling-group $R --auto-scaling-group-name "$asg" --force-delete
  done
  [[ -z "${asgs:-}" ]] && say "  No ASGs."

  # 3) Load balancers v2 and Target Groups
  log "Delete ALB/NLB + Target Groups"
  local lb_arns
  lb_arns=$(aws elbv2 describe-load-balancers $R \
    --query "LoadBalancers[?VpcId=='$vpc_id'].LoadBalancerArn" --output text 2>/dev/null | tr -s ' ' || true)
  for lb in $lb_arns; do
    say "  LBv2: $lb"
    run aws elbv2 delete-load-balancer $R --load-balancer-arn "$lb"
  done
  local tg_arns
  tg_arns=$(aws elbv2 describe-target-groups $R \
    --query "TargetGroups[?VpcId=='$vpc_id'].TargetGroupArn" --output text 2>/dev/null | tr -s ' ' || true)
  for tg in $tg_arns; do
    say "  TG: $tg"
    run aws elbv2 delete-target-group $R --target-group-arn "$tg"
  done
  [[ -z "${lb_arns:-}${tg_arns:-}" ]] && say "  No ALB/NLB."

  # 4) Classic ELBs
  log "Delete classic ELBs (v1)"
  local elbs
  elbs=$(aws elb describe-load-balancers $R \
    --query "LoadBalancerDescriptions[?contains(VPCId, \`$vpc_id\`)].LoadBalancerName" --output text 2>/dev/null | tr -s ' ' || true)
  for e in $elbs; do
    say "  ELBv1: $e"
    run aws elb delete-load-balancer $R --load-balancer-name "$e"
  done
  [[ -z "${elbs:-}" ]] && say "  No classic ELBs."

  # 5) NAT GWs (and release EIPs)
  log "Delete NAT Gateways + release EIPs"
  local nats
  nats=$(aws ec2 describe-nat-gateways $R --filter Name=vpc-id,Values=$vpc_id \
    --query "NatGateways[].NatGatewayId" --output text 2>/dev/null | tr -s ' ' || true)
  for nat in $nats; do
    local allocs
    allocs=$(aws ec2 describe-nat-gateways $R --nat-gateway-ids "$nat" \
      --query "NatGateways[0].NatGatewayAddresses[].AllocationId" --output text | tr -s ' ' || true)
    say "  NAT: $nat"
    run aws ec2 delete-nat-gateway $R --nat-gateway-id "$nat"
    $EXECUTE && wait_nat_deleted "$R" "$nat"
    for a in $allocs; do
      say "  Release EIP alloc: $a"
      run aws ec2 release-address $R --allocation-id "$a"
    done
  done
  [[ -z "${nats:-}" ]] && say "  No NAT GWs."

  # 6) VPC endpoints
  log "Delete VPC Endpoints"
  local vpces
  vpces=$(aws ec2 describe-vpc-endpoints $R --filters Name=vpc-id,Values=$vpc_id \
    --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null | tr -s ' ' || true)
  for e in $vpces; do
    say "  VPCE: $e"
    run aws ec2 delete-vpc-endpoints $R --vpc-endpoint-ids "$e"
  done
  [[ -z "${vpces:-}" ]] && say "  No VPC endpoints."

  # 7) Flow logs
  log "Delete VPC Flow Logs"
  local flowlogs
  flowlogs=$(aws ec2 describe-flow-logs $R --filter Name=resource-id,Values=$vpc_id \
    --query "FlowLogs[].FlowLogId" --output text 2>/dev/null | tr -s ' ' || true)
  for fl in $flowlogs; do
    say "  FlowLog: $fl"
    run aws ec2 delete-flow-logs $R --flow-log-ids "$fl"
  done
  [[ -z "${flowlogs:-}" ]] && say "  No flow logs."

  # 8) Instance Connect Endpoints
  log "Delete EC2 Instance Connect Endpoints"
  local eices
  eices=$(aws ec2 describe-instance-connect-endpoints $R --filters Name=vpc-id,Values=$vpc_id \
    --query "InstanceConnectEndpoints[].InstanceConnectEndpointId" --output text 2>/dev/null | tr -s ' ' || true)
  for id in $eices; do
    say "  EICE: $id"
    run aws ec2 delete-instance-connect-endpoint $R --instance-connect-endpoint-id "$id"
  done
  [[ -z "${eices:-}" ]] && say "  No EICE."

  # 9) Route53 Resolver endpoints
  log "Delete Route53 Resolver endpoints"
  local rslvrs
  rslvrs=$(aws route53resolver list-resolver-endpoints $R \
    --query "ResolverEndpoints[?VpcId=='$vpc_id'].Id" --output text 2>/dev/null | tr -s ' ' || true)
  for rid in $rslvrs; do
    say "  Resolver endpoint: $rid"
    run aws route53resolver delete-resolver-endpoint $R --resolver-endpoint-id "$rid"
  done
  [[ -z "${rslvrs:-}" ]] && say "  No resolver endpoints."

  # 10) Peering / VPN / TGW / IGWs
  log "Delete peering, VPN, TGW, IGWs"
  local pcxs
  pcxs=$(aws ec2 describe-vpc-peering-connections $R \
    --query "VpcPeeringConnections[?RequesterVpcInfo.VpcId=='$vpc_id' || AccepterVpcInfo.VpcId=='$vpc_id'].VpcPeeringConnectionId" \
    --output text 2>/dev/null | tr -s ' ' || true)
  for pcx in $pcxs; do
    say "  Peering: $pcx"
    run aws ec2 delete-vpc-peering-connection $R --vpc-peering-connection-id "$pcx"
  done

  local vgws
  vgws=$(aws ec2 describe-vpn-gateways $R --filters Name=attachments.vpc-id,Values=$vpc_id \
    --query "VpnGateways[].VpnGatewayId" --output text 2>/dev/null | tr -s ' ' || true)
  for vgw in $vgws; do
    say "  VGW: $vgw"
    run aws ec2 detach-vpn-gateway $R --vpn-gateway-id "$vgw" --vpc-id "$vpc_id"
    run aws ec2 delete-vpn-gateway $R --vpn-gateway-id "$vgw"
  done

  local tgwa
  tgwa=$(aws ec2 describe-transit-gateway-attachments $R --filters Name=resource-type,Values=vpc Name=resource-id,Values=$vpc_id \
    --query "TransitGatewayAttachments[].TransitGatewayAttachmentId" --output text 2>/dev/null | tr -s ' ' || true)
  for tga in $tgwa; do
    say "  TGW attachment: $tga"
    run aws ec2 delete-transit-gateway-attachment $R --transit-gateway-attachment-id "$tga"
  done

  local igws
  igws=$(aws ec2 describe-internet-gateways $R --filters Name=attachment.vpc-id,Values=$vpc_id \
    --query "InternetGateways[].InternetGatewayId" --output text 2>/dev/null | tr -s ' ' || true)
  for igw in $igws; do
    say "  IGW: $igw"
    run aws ec2 detach-internet-gateway $R --internet-gateway-id "$igw" --vpc-id "$vpc_id"
    run aws ec2 delete-internet-gateway $R --internet-gateway-id "$igw"
  done

  local eoigw
  eoigw=$(aws ec2 describe-egress-only-internet-gateways $R \
    --query "EgressOnlyInternetGateways[?Attachments[?VpcId=='$vpc_id']].EgressOnlyInternetGatewayId" --output text 2>/dev/null | tr -s ' ' || true)
  for e in $eoigw; do
    say "  Egress-only IGW: $e"
    run aws ec2 delete-egress-only-internet-gateway $R --egress-only-internet-gateway-id "$e"
  done

  # 11) Non-main route tables → remove default routes → disassociate → delete
  log "Delete non-main route tables"
  local rtbs
  rtbs=$(aws ec2 describe-route-tables $R --filters Name=vpc-id,Values=$vpc_id \
    --query "RouteTables[?!(Associations[?Main==\`true\`]|[0].Main)].RouteTableId" --output text 2>/dev/null | tr -s ' ' || true)
  for rtb in $rtbs; do
    safe_delroute "$rtb" "--destination-cidr-block 0.0.0.0/0"
    safe_delroute "$rtb" "--destination-ipv6-cidr-block ::/0"
    local assocs
    assocs=$(aws ec2 describe-route-tables $R --route-table-ids "$rtb" \
      --query "RouteTables[0].Associations[].RouteTableAssociationId" --output text | tr -s ' ' || true)
    for a in $assocs; do
      run aws ec2 disassociate-route-table $R --association-id "$a"
    done
    say "  Delete RTB: $rtb"
    run aws ec2 delete-route-table $R --route-table-id "$rtb"
  done
  [[ -z "${rtbs:-}" ]] && say "  No non-main route tables."

  # 12) Non-default NACLs
  log "Delete non-default NACLs"
  local nacls
  nacls=$(aws ec2 describe-network-acls $R --filters Name=vpc-id,Values=$vpc_id \
    --query "NetworkAcls[?IsDefault==\`false\`].NetworkAclId" --output text 2>/dev/null | tr -s ' ' || true)
  for nacl in $nacls; do
    say "  NACL: $nacl"
    run aws ec2 delete-network-acl $R --network-acl-id "$nacl"
  done
  [[ -z "${nacls:-}" ]] && say "  No custom NACLs."

  # 13) Non-default Security Groups
  log "Delete non-default Security Groups"
  local sgs
  sgs=$(aws ec2 describe-security-groups $R --filters Name=vpc-id,Values=$vpc_id \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null | tr -s ' ' || true)
  for sg in $sgs; do
    say "  SG: $sg"
    run aws ec2 delete-security-group $R --group-id "$sg" || true
  done
  [[ -z "${sgs:-}" ]] && say "  No custom SGs."

  # 14) Subnets
  log "Delete subnets"
  local subnets
  subnets=$(aws ec2 describe-subnets $R --filters Name=vpc-id,Values=$vpc_id \
    --query "Subnets[].SubnetId" --output text 2>/dev/null | tr -s ' ' || true)
  for sn in $subnets; do
    say "  Subnet: $sn"
    run aws ec2 delete-subnet $R --subnet-id "$sn" || true
  done
  [[ -z "${subnets:-}" ]] && say "  No subnets."

  # 15) Managed services (optional/unsafe in real envs)
  if [[ "$INCLUDE_MANAGED" == true ]]; then
    log "Managed services (DANGEROUS – lab only)"
    # RDS
    local dbs dbsgs
    dbs=$(aws rds describe-db-instances $R --query "DBInstances[?DBSubnetGroup.VpcId=='$vpc_id'].DBInstanceIdentifier" --output text 2>/dev/null | tr -s ' ' || true)
    for db in $dbs; do
      say "  RDS: $db (skip final snapshot)"
      run aws rds delete-db-instance $R --db-instance-identifier "$db" --skip-final-snapshot || true
    done
    dbsgs=$(aws rds describe-db-subnet-groups $R --query "DBSubnetGroups[?VpcId=='$vpc_id'].DBSubnetGroupName" --output text 2>/dev/null | tr -s ' ' || true)
    for g in $dbsgs; do
      say "  RDS subnet group: $g"
      run aws rds delete-db-subnet-group $R --db-subnet-group-name "$g" || true
    done
    # EFS (delete mount targets in our subnets, then FS best-effort)
    local vpc_sn
    vpc_sn=$(aws ec2 describe-subnets $R --filters Name=vpc-id,Values=$vpc_id --query "Subnets[].SubnetId" --output text)
    for fs in $(aws efs describe-file-systems $R --query "FileSystems[].FileSystemId" --output text 2>/dev/null); do
      mts=$(aws efs describe-mount-targets $R --file-system-id "$fs" --query "MountTargets[].{Id:MountTargetId,Subnet:SubnetId}" --output text 2>/dev/null || true)
      while read -r mt mt_subnet; do
        [[ -z "$mt" ]] && continue
        if [[ " $vpc_sn " == *" $mt_subnet "* ]]; then
          say "  EFS MT: $mt (subnet $mt_subnet)"
          run aws efs delete-mount-target $R --mount-target-id "$mt" || true
        fi
      done <<< "$mts"
      run aws efs delete-file-system $R --file-system-id "$fs" || true
    done
    # EKS
    for c in $(aws eks list-clusters $R --query "clusters[]" --output text 2>/dev/null || true); do
      v=$(aws eks describe-cluster $R --name "$c" --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null || true)
      if [[ "$v" == "$vpc_id" ]]; then
        say "  EKS cluster: $c"
        run aws eks delete-cluster $R --name "$c" || true
      fi
    done
    # OpenSearch
    for d in $(aws opensearch list-domain-names $R --query "DomainNames[].DomainName" --output text 2>/dev/null || true); do
      v=$(aws opensearch describe-domain $R --domain-name "$d" --query "DomainStatus.VPCOptions.VPCId" --output text 2>/dev/null || true)
      if [[ "$v" == "$vpc_id" ]]; then
        say "  OpenSearch domain: $d"
        run aws opensearch delete-domain $R --domain-name "$d" || true
      fi
    done
    # ElastiCache subnet groups
    for csg in $(aws elasticache describe-cache-subnet-groups $R --query "CacheSubnetGroups[?VpcId=='$vpc_id'].CacheSubnetGroupName" --output text 2>/dev/null | tr -s ' ' || true); do
      say "  ElastiCache subnet group: $csg"
      run aws elasticache delete-cache-subnet-group $R --cache-subnet-group-name "$csg" || true
    done
    # MSK best-effort
    aws kafka list-clusters-v2 $R --query "ClusterInfoList[].ClusterArn" --output text 2>/dev/null | while read -r arn; do
      [[ -z "$arn" ]] && continue
      v=$(aws kafka describe-cluster-v2 $R --cluster-arn "$arn" --query "ClusterInfo.VpcConfig.VpcId" --output text 2>/dev/null || true)
      if [[ "$v" == "$vpc_id" ]]; then
        say "  MSK: $arn"
        cur=$(aws kafka describe-cluster-v2 $R --cluster-arn "$arn" --query 'ClusterInfo.CurrentVersion' --output text 2>/dev/null || echo "")
        [[ -n "$cur" ]] && run aws kafka delete-cluster $R --cluster-arn "$arn" --current-version "$cur" || true
      fi
    done
    # FSx / Redshift / Directory Service best-effort
    aws fsx describe-file-systems $R --query "FileSystems[].FileSystemId" --output text 2>/dev/null | \
      xargs -r -n1 -I{} bash -c 'echo "  FSx: {}"; '"$(typeset -f run)";' run aws fsx delete-file-system '"$R"' --file-system-id {} || true'
    aws redshift describe-clusters $R --query "Clusters[?VpcId=='$vpc_id'].ClusterIdentifier" --output text 2>/dev/null | \
      xargs -r -n1 -I{} bash -c 'echo "  Redshift: {}"; '"$(typeset -f run)";' run aws redshift delete-cluster '"$R"' --cluster-identifier {} --skip-final-cluster-snapshot || true'
    aws ds describe-directories $R --query "DirectoryDescriptions[?VpcSettings.VpcId=='$vpc_id'].DirectoryId" --output text 2>/dev/null | \
      xargs -r -n1 -I{} bash -c 'echo "  Directory Service: {}"; '"$(typeset -f run)";' run aws ds delete-directory '"$R"' --directory-id {} || true'
  else
    log "Managed services: SKIPPED (use --include-managed to delete lab services)"
  fi

  # 16) Unattached ENIs (must be last sweep before VPC delete)
  log "Delete unattached ENIs (available)"
  local enis
  enis=$(aws ec2 describe-network-interfaces $R --filters Name=vpc-id,Values=$vpc_id \
    --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null | tr -s ' ' || true)
  for eni in $enis; do
    st=$(aws ec2 describe-network-interfaces $R --network-interface-ids "$eni" --query "NetworkInterfaces[0].Status" --output text)
    at=$(aws ec2 describe-network-interfaces $R --network-interface-ids "$eni" --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null || true)
    if [[ "$st" == "available" && "$at" == "None" ]]; then
      say "  ENI: $eni"
      run aws ec2 delete-network-interface $R --network-interface-id "$eni"
    fi
  done

  # 17) Try to delete VPC
  log "Delete VPC"
  run aws ec2 delete-vpc $R --vpc-id "$vpc_id" || say "  VPC delete failed (likely remaining dependency). Re-run with plan and check ENIs/route tables."
}

# MAIN
regions=$(get_regions)
for reg in $regions; do
  R="--region $reg"
  log "Scanning region: $reg"
  vpcs_json=$(aws ec2 describe-vpcs $R --query "Vpcs[].{Id:VpcId,IsDefault:IsDefault}" --output json)
  # shellcheck disable=SC2207
  mapfile -t vpc_ids < <(echo "$vpcs_json" | jq -r '.[] | .Id')
  mapfile -t vpc_isdef < <(echo "$vpcs_json" | jq -r '.[] | .IsDefault')

  if [[ "${#vpc_ids[@]}" -eq 0 ]]; then
    say "  No VPCs in $reg"
    continue
  fi

  say "  Found VPCs:"
  paste <(printf "%s\n" "${vpc_ids[@]}") <(printf "%s\n" "${vpc_isdef[@]}") | awk '{printf "   - %-20s IsDefault=%s\n",$1,$2}'

  # Process each VPC
  for vid in "${vpc_ids[@]}"; do
    teardown_vpc "$vid" "$reg"
  done
done

say "\nAll regions processed."

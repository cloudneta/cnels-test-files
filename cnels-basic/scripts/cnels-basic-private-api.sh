#!/usr/bin/env bash
# Run on EKS-BASTION as the same user that created cnels-basic.
set -Eeuo pipefail
umask 077
cluster=cnels-basic
export AWS_DEFAULT_REGION=ap-northeast-2 AWS_REGION=ap-northeast-2 AWS_PAGER=''
log=$(mktemp "./cnels-basic-private-api-XXXXXXXX")
printf 'Result file: %s/%s\n' "$PWD" "${log#./}"
run() {
  trap 'rc=$?; if (( rc != 0 )); then echo "RESULT=FAIL (exit $rc)"; fi' EXIT
  fail() { echo "$*" >&2; exit 1; }
  cluster_info() {
    aws eks describe-cluster --name "$cluster" --query cluster --output json
  }

  echo "Target: $cluster ($AWS_REGION)"
  info=$(cluster_info)
  endpoint=$(jq -er '.endpoint' <<<"$info")
  vpc=$(jq -er '.resourcesVpcConfig.vpcId' <<<"$info")
  cluster_sg=$(jq -er '.resourcesVpcConfig.clusterSecurityGroupId' <<<"$info")
  [[ $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}') == "$endpoint" ]] ||
    fail "Current kubectl context points to a different API endpoint."

  metadata=http://169.254.169.254/latest
  imds=(curl -fsS --noproxy '*' --max-time 5)
  token=$("${imds[@]}" -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' "$metadata/api/token")
  instance=$("${imds[@]}" -H "X-aws-ec2-metadata-token: $token" "$metadata/meta-data/instance-id")
  unset token
  bastion=$(aws ec2 describe-instances --instance-ids "$instance" --query 'Reservations[0].Instances[0]' --output json)
  jq -e --arg vpc "$vpc" '.VpcId == $vpc and any(.Tags[]; .Key == "Name" and .Value == "EKS-BASTION") and (.SecurityGroups | length == 1)' <<<"$bastion" >/dev/null ||
    fail "Expected EKS-BASTION in the cluster VPC with one security group."
  bastion_sg=$(jq -er '.SecurityGroups[0].GroupId' <<<"$bastion")

  echo "Checking ingress: $bastion_sg -> $cluster_sg TCP/443"
  rules=$(aws ec2 describe-security-groups --group-ids "$cluster_sg" --query 'SecurityGroups[0].IpPermissions' --output json)
  if jq -e --arg sg "$bastion_sg" 'any(.[]; any(.UserIdGroupPairs[]?; .GroupId == $sg) and (.IpProtocol == "-1" or (.IpProtocol == "tcp" and .FromPort <= 443 and .ToPort >= 443)))' <<<"$rules" >/dev/null; then
    echo 'Bastion security group already allowed.'
  else
    if ! message=$(aws ec2 authorize-security-group-ingress --group-id "$cluster_sg" --protocol tcp --port 443 --source-group "$bastion_sg" 2>&1); then
      [[ $message == *'(InvalidPermission.Duplicate)'* ]] || fail "$message"
    fi
    echo 'Bastion TCP/443 rule present.'
  fi

  private_only='(.status == "ACTIVE") and (.resourcesVpcConfig | .endpointPrivateAccess == true and .endpointPublicAccess == false)'
  if ! jq -e "$private_only" <<<"$info" >/dev/null; then
    status=$(jq -r '.status' <<<"$info")
    if [[ $status == ACTIVE ]]; then
      eksctl utils update-cluster-vpc-config --cluster "$cluster" --region "$AWS_REGION" \
        --private-access=true --public-access=false --approve
    elif [[ $status != UPDATING ]]; then
      fail "Unexpected cluster status: $status"
    fi
    echo 'Waiting for ACTIVE and Private Only (up to 20 minutes).'
    deadline=$((SECONDS + 1200))
    until info=$(cluster_info) && jq -e "$private_only" <<<"$info" >/dev/null; do
      (( SECONDS < deadline )) || fail "Timed out waiting for Private Only. Inspect the EKS update before retrying."
      sleep 15
    done
  fi
  jq -c '{status, publicAccess:.resourcesVpcConfig.endpointPublicAccess, privateAccess:.resourcesVpcConfig.endpointPrivateAccess}' <<<"$info"

  echo 'Checking cnels-cpu from the Bastion (allowing for DNS propagation).'
  selector='eks.amazonaws.com/nodegroup=cnels-cpu'
  deadline=$((SECONDS + 300))
  until nodes=$(kubectl --request-timeout=10s get nodes -l "$selector" -o json) &&
    jq -e '(.items | length == 1) and any(.items[0].status.conditions[]; .type == "Ready" and .status == "True")' <<<"$nodes" >/dev/null; do
    (( SECONDS < deadline )) || fail "Could not verify one Ready cnels-cpu node from the Bastion."
    sleep 10
  done
  kubectl --request-timeout=10s get nodes -l "$selector" -o wide
  echo 'RESULT=PASS'
}

run 2>&1 | tee -a "$log"

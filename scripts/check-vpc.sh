#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────
# Validate an existing VPC for CDK deployment
# Checks required subnets and VPC endpoints
# ──────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 --vpc-id VPC_ID [--region REGION]

Check if an existing VPC has all required resources for the gateway stack.

Required:
  --vpc-id VPC_ID     VPC to validate

Optional:
  --region REGION     AWS region (default: ap-northeast-1)

Example:
  $0 --vpc-id vpc-0abc123def456
EOF
  exit 1
}

VPC_ID=""
REGION="ap-northeast-1"

while [[ $# -gt 0 ]]; do
  case $1 in
    --vpc-id)   VPC_ID="$2"; shift 2 ;;
    --region)   REGION="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *)          echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$VPC_ID" ]]; then
  echo "Error: --vpc-id is required."
  usage
fi

PASS=0
FAIL=0
WARNINGS=""

check_pass() {
  echo "  [PASS] $1"
  PASS=$((PASS + 1))
}

check_fail() {
  echo "  [FAIL] $1"
  FAIL=$((FAIL + 1))
  WARNINGS="${WARNINGS}\n  - $1"
}

echo "=============================="
echo "VPC Validation: $VPC_ID"
echo "Region: $REGION"
echo "=============================="
echo ""

# ── 1. Check VPC exists ──
echo "1. VPC existence"
VPC_STATE=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
  --query 'Vpcs[0].State' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$VPC_STATE" == "available" ]]; then
  VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
    --query 'Vpcs[0].CidrBlock' --output text)
  check_pass "VPC $VPC_ID exists (CIDR: $VPC_CIDR)"
else
  check_fail "VPC $VPC_ID not found or not available"
  echo ""
  echo "Cannot proceed without a valid VPC."
  exit 1
fi

# ── 2. Check private subnets with egress (at least 2 AZs) ──
echo ""
echo "2. Private subnets with NAT/egress (need >= 2 AZs)"

# Get all subnets in this VPC
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region "$REGION" \
  --query 'Subnets[*].SubnetId' --output text)

PRIVATE_AZS=()
for SUBNET_ID in $SUBNET_IDS; do
  # Check if subnet has a route to 0.0.0.0/0 via NAT gateway
  RT_ID=$(aws ec2 describe-route-tables --filters \
    "Name=association.subnet-id,Values=$SUBNET_ID" \
    --region "$REGION" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "None")

  if [[ "$RT_ID" == "None" || "$RT_ID" == "" ]]; then
    # Try main route table
    RT_ID=$(aws ec2 describe-route-tables --filters \
      "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
      --region "$REGION" \
      --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "None")
  fi

  if [[ "$RT_ID" != "None" && "$RT_ID" != "" ]]; then
    HAS_NAT=$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" --region "$REGION" \
      --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && NatGatewayId!=null].NatGatewayId" \
      --output text 2>/dev/null || echo "")

    if [[ -n "$HAS_NAT" ]]; then
      AZ=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --region "$REGION" \
        --query 'Subnets[0].AvailabilityZone' --output text)
      PRIVATE_AZS+=("$AZ")
      echo "     Private subnet: $SUBNET_ID ($AZ)"
    fi
  fi
done

UNIQUE_AZS=($(printf '%s\n' "${PRIVATE_AZS[@]}" | sort -u))
if [[ ${#UNIQUE_AZS[@]} -ge 2 ]]; then
  check_pass "Found ${#UNIQUE_AZS[@]} AZs with private subnets: ${UNIQUE_AZS[*]}"
elif [[ ${#UNIQUE_AZS[@]} -eq 1 ]]; then
  check_fail "Only 1 AZ with private subnets (need >= 2): ${UNIQUE_AZS[*]}"
else
  check_fail "No private subnets with NAT gateway found"
fi

# ── 3. Check VPC Endpoints ──
echo ""
echo "3. VPC Endpoints"

check_endpoint() {
  local SERVICE_SUFFIX="$1"
  local DISPLAY_NAME="$2"
  local SERVICE_NAME="com.amazonaws.${REGION}.${SERVICE_SUFFIX}"

  ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=service-name,Values=$SERVICE_NAME" \
    "Name=vpc-endpoint-state,Values=available" \
    --region "$REGION" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null || echo "None")

  if [[ "$ENDPOINT_ID" != "None" && "$ENDPOINT_ID" != "" ]]; then
    check_pass "$DISPLAY_NAME ($SERVICE_NAME)"
  else
    check_fail "$DISPLAY_NAME ($SERVICE_NAME) — not found"
  fi
}

check_endpoint "kinesis-streams" "Kinesis Streams (Interface)"
check_endpoint "ecr.api"        "ECR API (Interface)"
check_endpoint "ecr.dkr"        "ECR Docker (Interface)"
check_endpoint "s3"             "S3 (Gateway)"
check_endpoint "logs"           "CloudWatch Logs (Interface)"

# ── 4. Check DNS resolution is enabled ──
echo ""
echo "4. VPC DNS settings"
DNS_SUPPORT=$(aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsSupport --region "$REGION" \
  --query 'EnableDnsSupport.Value' --output text)
DNS_HOSTNAMES=$(aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsHostnames --region "$REGION" \
  --query 'EnableDnsHostnames.Value' --output text)

if [[ "$DNS_SUPPORT" == "true" && "$DNS_HOSTNAMES" == "true" ]]; then
  check_pass "DNS Support and DNS Hostnames enabled"
else
  check_fail "DNS Support ($DNS_SUPPORT) and/or DNS Hostnames ($DNS_HOSTNAMES) not enabled — required for VPC endpoints"
fi

# ── Summary ──
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Missing resources:$WARNINGS"
  echo ""
  echo "Please add the missing resources before deploying with --vpc-id $VPC_ID"
  echo ""
  echo "Quick fix commands:"

  # Generate fix commands
  if echo -e "$WARNINGS" | grep -q "Kinesis Streams"; then
    echo "  aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.${REGION}.kinesis-streams --vpc-endpoint-type Interface --subnet-ids <SUBNET_IDS> --region $REGION"
  fi
  if echo -e "$WARNINGS" | grep -q "ECR API"; then
    echo "  aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.${REGION}.ecr.api --vpc-endpoint-type Interface --subnet-ids <SUBNET_IDS> --region $REGION"
  fi
  if echo -e "$WARNINGS" | grep -q "ECR Docker"; then
    echo "  aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.${REGION}.ecr.dkr --vpc-endpoint-type Interface --subnet-ids <SUBNET_IDS> --region $REGION"
  fi
  if echo -e "$WARNINGS" | grep -q "S3"; then
    echo "  aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.${REGION}.s3 --vpc-endpoint-type Gateway --route-table-ids <RT_IDS> --region $REGION"
  fi
  if echo -e "$WARNINGS" | grep -q "CloudWatch Logs"; then
    echo "  aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.${REGION}.logs --vpc-endpoint-type Interface --subnet-ids <SUBNET_IDS> --region $REGION"
  fi

  exit 1
else
  echo ""
  echo "VPC $VPC_ID is ready for deployment!"
  echo ""
  echo "Deploy with:"
  echo "  ./scripts/deploy.sh --stack-name <NAME> --platform-name <PLATFORM> --kinesis-stream <STREAM> --vpc-id $VPC_ID"
  exit 0
fi

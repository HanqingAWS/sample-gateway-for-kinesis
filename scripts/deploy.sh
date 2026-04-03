#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────
# Deploy / Update CDK stack for ad callback gateway
# One ECS cluster serves multiple ad platforms via path-based routing
# ──────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 --stack-name NAME --gateway-name NAME --route /PATH:STREAM [OPTIONS]

Required:
  --stack-name NAME         CloudFormation stack name (e.g., AdsCallbackGateway)
  --gateway-name NAME       Gateway identifier for resource naming (e.g., ads-gateway)
  --route /PATH:STREAM      Path-to-Kinesis-stream mapping (repeatable)
                            e.g., --route /guangdiantong:gdt_stream --route /toutiao:tt_stream

Optional:
  --kinesis-region REGION   AWS region (default: ap-northeast-1)
  --vpc-id VPC_ID           Use existing VPC (skip VPC creation). Run check-vpc.sh first.
  --vpc-cidr CIDR           VPC CIDR for new VPC (default: 10.0.0.0/16, ignored if --vpc-id set)
  --ecs-count N             Desired ECS task count (default: 3)
  --ebs-size GB             EBS volume size per task in GB (default: 1000)
  --ebs-retention-hours N   Hours to retain data on EBS disk buffer (default: 24)
  --ebs-reclaim-percent N   Trigger disk reclaim when usage exceeds this % (default: 80)
  --skip-build              Skip Docker image build and push
  --destroy                 Destroy the stack instead of deploying

Examples:
  # Deploy with multiple ad platforms (one cluster handles all)
  $0 --stack-name AdsCallbackGateway \\
     --gateway-name ads-gateway \\
     --route /guangdiantong:guangdiantong_kinesis_stream \\
     --route /toutiao:toutiao_kinesis_stream \\
     --route /kuaishou:kuaishou_kinesis_stream \\
     --route /baidu:baidu_kinesis_stream \\
     --vpc-id vpc-0abc123def456

  # Update routes (add a new platform)
  $0 --stack-name AdsCallbackGateway \\
     --gateway-name ads-gateway \\
     --route /guangdiantong:guangdiantong_kinesis_stream \\
     --route /toutiao:toutiao_kinesis_stream \\
     --route /kuaishou:kuaishou_kinesis_stream \\
     --route /baidu:baidu_kinesis_stream \\
     --route /unity:unity_kinesis_stream \\
     --skip-build
EOF
  exit 1
}

# ── Parse arguments ──
STACK_NAME=""
GATEWAY_NAME=""
ROUTES=()
KINESIS_REGION="ap-northeast-1"
VPC_ID=""
VPC_CIDR="10.0.0.0/16"
ECS_COUNT="3"
EBS_SIZE="1000"
EBS_RETENTION_HOURS="24"
EBS_RECLAIM_PERCENT="80"
SKIP_BUILD=false
DESTROY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --stack-name)       STACK_NAME="$2"; shift 2 ;;
    --gateway-name)     GATEWAY_NAME="$2"; shift 2 ;;
    --route)            ROUTES+=("$2"); shift 2 ;;
    --kinesis-region)   KINESIS_REGION="$2"; shift 2 ;;
    --vpc-id)           VPC_ID="$2"; shift 2 ;;
    --vpc-cidr)         VPC_CIDR="$2"; shift 2 ;;
    --ecs-count)        ECS_COUNT="$2"; shift 2 ;;
    --ebs-size)         EBS_SIZE="$2"; shift 2 ;;
    --ebs-retention-hours) EBS_RETENTION_HOURS="$2"; shift 2 ;;
    --ebs-reclaim-percent) EBS_RECLAIM_PERCENT="$2"; shift 2 ;;
    --skip-build)       SKIP_BUILD=true; shift ;;
    --destroy)          DESTROY=true; shift ;;
    -h|--help)          usage ;;
    *)                  echo "Unknown option: $1"; usage ;;
  esac
done

# ── Validate required arguments ──
if [[ -z "$STACK_NAME" || -z "$GATEWAY_NAME" ]]; then
  echo "Error: --stack-name and --gateway-name are required."
  echo ""
  usage
fi

if [[ ${#ROUTES[@]} -eq 0 && "$DESTROY" == "false" ]]; then
  echo "Error: at least one --route is required for deployment."
  echo ""
  usage
fi

# Build ROUTE_MAP string: /path1:stream1,/path2:stream2
ROUTE_MAP=$(IFS=','; echo "${ROUTES[*]}")

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CDK_DIR="$PROJECT_DIR/deploy/cdk"

echo "=============================="
echo "Stack:     $STACK_NAME"
echo "Gateway:   $GATEWAY_NAME"
echo "Region:    $KINESIS_REGION"
echo "Routes:"
for r in "${ROUTES[@]}"; do
  echo "  $r"
done
if [[ -n "$VPC_ID" ]]; then
  echo "VPC:       $VPC_ID (existing)"
else
  echo "VPC:       New ($VPC_CIDR)"
fi
echo "ECS Tasks: $ECS_COUNT"
echo "EBS Size:  ${EBS_SIZE} GB"
echo "EBS Retention: ${EBS_RETENTION_HOURS}h, reclaim at ${EBS_RECLAIM_PERCENT}%"
echo "=============================="

# ── Detect AWS account ──
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$KINESIS_REGION")
echo "AWS Account: $ACCOUNT_ID"

# ── Install CDK dependencies if needed ──
if [[ ! -d "$CDK_DIR/node_modules" ]]; then
  echo ""
  echo "=== Installing CDK dependencies ==="
  cd "$CDK_DIR" && npm install
fi

# ── Bootstrap CDK if needed ──
echo ""
echo "=== Checking CDK bootstrap ==="
if ! aws cloudformation describe-stacks --stack-name CDKToolkit --region "$KINESIS_REGION" &>/dev/null; then
  echo "CDK not bootstrapped, running bootstrap..."
  cd "$CDK_DIR" && npx cdk bootstrap "aws://${ACCOUNT_ID}/${KINESIS_REGION}"
else
  echo "CDK already bootstrapped."
fi

# ── Destroy mode ──
if [[ "$DESTROY" == "true" ]]; then
  echo ""
  echo "=== Destroying stack: $STACK_NAME ==="
  cd "$CDK_DIR"
  STACK_NAME="$STACK_NAME" \
  GATEWAY_NAME="$GATEWAY_NAME" \
  ROUTE_MAP="$ROUTE_MAP" \
  KINESIS_REGION="$KINESIS_REGION" \
  VPC_ID="$VPC_ID" \
  VPC_CIDR="$VPC_CIDR" \
  ECS_DESIRED_COUNT="$ECS_COUNT" \
  EBS_SIZE_GB="$EBS_SIZE" \
  EBS_RETENTION_HOURS="$EBS_RETENTION_HOURS" \
  EBS_RECLAIM_PERCENT="$EBS_RECLAIM_PERCENT" \
  CDK_DEFAULT_ACCOUNT="$ACCOUNT_ID" \
  CDK_DEFAULT_REGION="$KINESIS_REGION" \
    npx cdk destroy "$STACK_NAME" --force
  echo "Stack $STACK_NAME destroyed."
  exit 0
fi

# ── Build and push Docker images (unless skipped) ──
if [[ "$SKIP_BUILD" == "false" ]]; then
  echo ""
  echo "=== Building and pushing Docker images ==="
  ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${KINESIS_REGION}.amazonaws.com"

  if aws ecr describe-repositories --repository-names "${GATEWAY_NAME}-nginx" --region "$KINESIS_REGION" &>/dev/null; then
    echo "ECR repos exist, building images..."
    aws ecr get-login-password --region "$KINESIS_REGION" | docker login --username AWS --password-stdin "$ECR_BASE"

    docker build --platform linux/arm64 -t "${GATEWAY_NAME}-nginx:latest" -f "$PROJECT_DIR/docker/nginx/Dockerfile" "$PROJECT_DIR/docker/nginx/"
    docker build --platform linux/arm64 -t "${GATEWAY_NAME}-vector:latest" -f "$PROJECT_DIR/docker/vector/Dockerfile" "$PROJECT_DIR/docker/vector/"

    docker tag "${GATEWAY_NAME}-nginx:latest" "${ECR_BASE}/${GATEWAY_NAME}-nginx:latest"
    docker tag "${GATEWAY_NAME}-vector:latest" "${ECR_BASE}/${GATEWAY_NAME}-vector:latest"

    docker push "${ECR_BASE}/${GATEWAY_NAME}-nginx:latest"
    docker push "${ECR_BASE}/${GATEWAY_NAME}-vector:latest"
  else
    echo "ECR repos not found. Will deploy CDK first, then build images."
  fi
fi

# ── Deploy CDK stack ──
echo ""
echo "=== Deploying CDK stack: $STACK_NAME ==="
cd "$CDK_DIR"

STACK_NAME="$STACK_NAME" \
GATEWAY_NAME="$GATEWAY_NAME" \
ROUTE_MAP="$ROUTE_MAP" \
KINESIS_REGION="$KINESIS_REGION" \
VPC_ID="$VPC_ID" \
VPC_CIDR="$VPC_CIDR" \
ECS_DESIRED_COUNT="$ECS_COUNT" \
EBS_SIZE_GB="$EBS_SIZE" \
EBS_RETENTION_HOURS="$EBS_RETENTION_HOURS" \
EBS_RECLAIM_PERCENT="$EBS_RECLAIM_PERCENT" \
CDK_DEFAULT_ACCOUNT="$ACCOUNT_ID" \
CDK_DEFAULT_REGION="$KINESIS_REGION" \
  npx cdk deploy "$STACK_NAME" --require-approval never

# ── If images weren't built yet (first deploy), build now ──
if [[ "$SKIP_BUILD" == "false" ]]; then
  ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${KINESIS_REGION}.amazonaws.com"
  if ! docker image inspect "${GATEWAY_NAME}-nginx:latest" &>/dev/null; then
    echo ""
    echo "=== Building and pushing Docker images (post-CDK) ==="
    aws ecr get-login-password --region "$KINESIS_REGION" | docker login --username AWS --password-stdin "$ECR_BASE"

    docker build --platform linux/arm64 -t "${GATEWAY_NAME}-nginx:latest" -f "$PROJECT_DIR/docker/nginx/Dockerfile" "$PROJECT_DIR/docker/nginx/"
    docker build --platform linux/arm64 -t "${GATEWAY_NAME}-vector:latest" -f "$PROJECT_DIR/docker/vector/Dockerfile" "$PROJECT_DIR/docker/vector/"

    docker tag "${GATEWAY_NAME}-nginx:latest" "${ECR_BASE}/${GATEWAY_NAME}-nginx:latest"
    docker tag "${GATEWAY_NAME}-vector:latest" "${ECR_BASE}/${GATEWAY_NAME}-vector:latest"

    docker push "${ECR_BASE}/${GATEWAY_NAME}-nginx:latest"
    docker push "${ECR_BASE}/${GATEWAY_NAME}-vector:latest"

    echo ""
    echo "=== Restarting ECS service to pick up new images ==="
    aws ecs update-service \
      --cluster "${GATEWAY_NAME}-cluster" \
      --service "${GATEWAY_NAME}-service" \
      --force-new-deployment \
      --region "$KINESIS_REGION" \
      --query 'service.serviceName' --output text
  fi
fi

echo ""
echo "=============================="
echo "Deploy complete!"
echo ""
echo "NLB DNS:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$KINESIS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='NlbDns'].OutputValue" \
  --output text
echo ""
echo "Routes: $ROUTE_MAP"
echo ""
echo "Test:"
for r in "${ROUTES[@]}"; do
  path="${r%%:*}"
  echo "  curl http://<NLB_DNS>${path}?account_id=123&click_id=test"
done
echo "  curl http://<NLB_DNS>/health"
echo "=============================="

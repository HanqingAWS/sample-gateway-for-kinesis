#!/bin/bash
set -euo pipefail

# Build and push Docker images to ECR
# Usage: ./scripts/build-and-push.sh [REGION] [ACCOUNT_ID]

REGION="${1:-ap-northeast-1}"
ACCOUNT_ID="${2:-$(aws sts get-caller-identity --query Account --output text)}"
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "=== ECR Login ==="
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_BASE"

echo "=== Building Nginx image ==="
docker build --platform linux/arm64 -t ads-callback-nginx:latest -f docker/nginx/Dockerfile docker/nginx/

echo "=== Building Vector image ==="
docker build --platform linux/arm64 -t ads-callback-vector:latest -f docker/vector/Dockerfile docker/vector/

echo "=== Tagging and pushing Nginx ==="
docker tag ads-callback-nginx:latest "${ECR_BASE}/ads-callback-nginx:latest"
docker push "${ECR_BASE}/ads-callback-nginx:latest"

echo "=== Tagging and pushing Vector ==="
docker tag ads-callback-vector:latest "${ECR_BASE}/ads-callback-vector:latest"
docker push "${ECR_BASE}/ads-callback-vector:latest"

echo "=== Done ==="
echo "Nginx:  ${ECR_BASE}/ads-callback-nginx:latest"
echo "Vector: ${ECR_BASE}/ads-callback-vector:latest"

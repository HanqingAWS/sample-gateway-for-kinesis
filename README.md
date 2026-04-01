# Sample Gateway for Kinesis

A high-performance, cost-effective replacement for AWS API Gateway → Kinesis integration, using **NLB + ECS Fargate (Nginx + Vector)** architecture.

## Background

AWS API Gateway charges $3.50 per million requests. For high-volume ad attribution callbacks (100M+ requests/month), this becomes a significant cost. This project replaces API Gateway with a self-managed Nginx + Vector pipeline that writes directly to Kinesis, achieving **~67% cost reduction** with **21,968 QPS** throughput and full downstream compatibility.

## Architecture

Each ad platform gets its own independent stack (NLB endpoint + ECS cluster + Kinesis stream). Multiple stacks can share the same VPC.

```
Ad Platform (GET /<path>?account_id=xxx&click_id=xxx&...)
        |
   NLB (TCP:80) ─── per-platform endpoint
        |
   +── ECS Fargate Task ×3 (4vCPU, 8GB, ARM64) ──+
   |                                                |
   |  Nginx (OpenResty) :8080                       |
   |    - Parse GET query string params             |
   |    - Lua: flatten to JSON (all strings)        |
   |    - POST JSON to Vector via localhost          |
   |    - Return HTTP 200 immediately               |
   |         |                                      |
   |         v                                      |
   |  Vector :8686                                  |
   |    - HTTP source receives JSON                 |
   |    - Clean metadata fields                     |
   |    - Disk buffer (EBS gp3, 1TB default)        |
   |    - Kinesis PutRecords (batched)              |
   |                                                |
   |  [EBS gp3: /var/lib/vector, auto-reclaim]      |
   +────────────────────────────────────────────────+
        |
   Kinesis Stream → Lambda Consumers (unchanged)
```

## Key Features

- **Multi-platform deployment**: One CDK stack per ad platform, same command to deploy/update, supports 4+ independent endpoints
- **Existing VPC support**: Deploy into production VPC with `--vpc-id`, or auto-create a new VPC
- **Disk buffering**: EBS-backed buffer (1TB default) survives Kinesis outages; auto-reclaim when disk > 80%; 24h data retention
- **Full compatibility**: 28/28 fields match API Gateway output; all values stored as strings
- **High throughput**: 21,968 QPS on 3 Fargate tasks (4c8g ARM64), 0 failed requests
- **Low latency**: p50=6ms, p99=31ms
- **One-command deploy**: `scripts/deploy.sh` handles npm install, CDK bootstrap, image build, and deploy

## Project Structure

```
deploy/cdk/
  bin/app.ts              # CDK app entry, reads env vars
  lib/nlb-ecs-stack.ts    # Main stack: VPC/NLB/ECS/EBS/IAM/VPC Endpoints
  package.json            # CDK dependencies
docker/
  nginx/
    Dockerfile            # OpenResty 1.25.3.2 + lua-resty-http
    nginx.conf            # Worker config, init_by_lua for env vars
    collect.lua           # Query string → JSON → POST to Vector
  vector/
    Dockerfile            # Vector 0.43.1 alpine + disk cleanup
    vector.toml           # HTTP source → clean → Kinesis sink
    entrypoint.sh         # Vector + background disk reclaim
scripts/
  deploy.sh               # One-command deploy/update/destroy
  check-vpc.sh            # Validate existing VPC readiness
  build-and-push.sh       # Build ARM64 images, push to ECR
docker-compose.yml        # Local development setup
test-report.html          # Comprehensive test & performance report
```

## Quick Start (Local Development)

```bash
git clone https://github.com/HanqingAWS/sample-gateway-for-kinesis.git
cd sample-gateway-for-kinesis

# Start with docker-compose
docker-compose up --build -d

# Test
curl "http://localhost:8080/test?account_id=123&click_id=abc"
# => {"status":"ok"}
```

## Production Deployment (CDK)

### Prerequisites

- AWS CLI configured with appropriate credentials
- Docker (for building ARM64 images)
- Node.js 18+ (CDK dependencies auto-installed by deploy script)

### Deploy with Defaults (Single Stack)

```bash
# All parameters optional — uses default stack name, platform name, and stream
./scripts/deploy.sh
```

### Deploy a Specific Platform

```bash
./scripts/deploy.sh \
  --stack-name GuangdiantongGateway \
  --platform-name guangdiantong \
  --kinesis-stream guangdiantong_kinesis_stream
```

Either command will:
1. Auto-install CDK dependencies (`npm install`) if not present
2. Auto-bootstrap CDK (`cdk bootstrap`) if not done
3. Create a new VPC with all required VPC endpoints
4. Deploy ECS Fargate cluster (3 tasks × 4vCPU 8GB ARM64)
5. Build and push Docker images to ECR
6. Output the NLB DNS endpoint

### Deploy into Existing VPC

For production environments, deploy into your existing VPC to share networking resources:

```bash
# Step 1: Validate VPC has required resources
./scripts/check-vpc.sh --vpc-id vpc-0abc123def456

# Step 2: Deploy (if check passes)
./scripts/deploy.sh \
  --stack-name GuangdiantongGateway \
  --platform-name guangdiantong \
  --kinesis-stream guangdiantong_kinesis_stream \
  --vpc-id vpc-0abc123def456
```

The `check-vpc.sh` script validates:
- Private subnets with NAT egress (≥ 2 AZs)
- Kinesis Streams VPC Endpoint (Interface)
- ECR API + Docker VPC Endpoints (Interface)
- S3 VPC Endpoint (Gateway)
- CloudWatch Logs VPC Endpoint (Interface)
- DNS Support and DNS Hostnames enabled

If any checks fail, it outputs the exact `aws ec2 create-vpc-endpoint` commands to fix them.

### Deploy Multiple Platforms (4 Stacks Example)

```bash
# All 4 platforms share the same VPC
VPC_ID="vpc-0abc123def456"

# 1. Guangdiantong (Tencent Ads)
./scripts/deploy.sh \
  --stack-name GuangdiantongGateway \
  --platform-name guangdiantong \
  --kinesis-stream guangdiantong_kinesis_stream \
  --vpc-id $VPC_ID

# 2. Toutiao (ByteDance)
./scripts/deploy.sh \
  --stack-name ToutiaoGateway \
  --platform-name toutiao \
  --kinesis-stream toutiao_kinesis_stream \
  --vpc-id $VPC_ID

# 3. Kuaishou
./scripts/deploy.sh \
  --stack-name KuaishouGateway \
  --platform-name kuaishou \
  --kinesis-stream kuaishou_kinesis_stream \
  --vpc-id $VPC_ID

# 4. Baidu
./scripts/deploy.sh \
  --stack-name BaiduGateway \
  --platform-name baidu \
  --kinesis-stream baidu_kinesis_stream \
  --vpc-id $VPC_ID
```

Each stack creates its own independent:
- NLB (internet-facing endpoint)
- ECS cluster + service
- ECR repositories
- EBS volumes
- CloudWatch log group
- IAM roles

### Update Existing Stack

Same command as deploy. CDK automatically detects changes and updates:

```bash
# Scale up to 5 tasks
./scripts/deploy.sh \
  --stack-name GuangdiantongGateway \
  --platform-name guangdiantong \
  --kinesis-stream guangdiantong_kinesis_stream \
  --vpc-id vpc-0abc123 \
  --ecs-count 5

# Update with code changes (rebuilds Docker images)
./scripts/deploy.sh \
  --stack-name GuangdiantongGateway \
  --platform-name guangdiantong \
  --kinesis-stream guangdiantong_kinesis_stream \
  --vpc-id vpc-0abc123
```

### Destroy a Stack

```bash
./scripts/deploy.sh \
  --stack-name GuangdiantongGateway \
  --platform-name guangdiantong \
  --kinesis-stream guangdiantong_kinesis_stream \
  --destroy
```

### All Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--stack-name` | No | `AdsCallbackGatewayStack` | CloudFormation stack name |
| `--platform-name` | No | `ads-callback` | Resource naming prefix (e.g., `guangdiantong`) |
| `--kinesis-stream` | No | `guangdiantong_attribution_event` | Target Kinesis stream name |
| `--kinesis-region` | No | `ap-northeast-1` | AWS region |
| `--vpc-id` | No | - | Existing VPC ID (creates new if omitted) |
| `--vpc-cidr` | No | `10.0.0.0/16` | CIDR for new VPC (ignored with `--vpc-id`) |
| `--ecs-count` | No | `3` | Desired ECS task count |
| `--ebs-size` | No | `1000` | EBS volume size per task (GB) |
| `--ebs-retention-hours` | No | `24` | Hours to retain data on disk buffer |
| `--ebs-reclaim-percent` | No | `80` | Trigger disk cleanup when usage exceeds % |
| `--skip-build` | No | `false` | Skip Docker image build/push |
| `--destroy` | No | `false` | Destroy stack instead of deploy |

## How It Works

1. **Nginx (OpenResty + Lua)** receives GET requests on port 8080
2. `collect.lua` extracts all query string parameters, flattens them into a JSON object (all values as strings), and POSTs to Vector via localhost
3. **Vector** receives the JSON, cleans metadata fields, and writes to Kinesis via `PutRecords` with batching (500 events / 5MB / 1s)
4. **Disk buffer** on EBS gp3 ensures data is not lost during Kinesis outages
5. **Disk cleanup** background process auto-reclaims space when usage exceeds threshold (default: 80%), deleting data older than retention period (default: 24h)

## Cost Comparison (100M requests/month, per platform)

| Component | API Gateway | NLB + ECS Fargate |
|-----------|-------------|-------------------|
| Request handling | $350 | NLB ~$16 |
| Compute | included | Fargate 3×4c8g ARM ~$87 |
| Storage | - | EBS 3×1TB gp3 ~$288 |
| **Total** | **~$350/mo** | **~$391/mo** |

> With 200GB EBS: ~$174/mo (50% saving). With 100GB EBS: ~$116/mo (67% saving).
> At 1B requests/month: API Gateway = $3,500 vs NLB+ECS = same fixed cost.
> EBS size should be chosen based on how long you need to buffer during Kinesis outages.

| EBS Size | Buffer Duration @ Peak | Buffer Duration @ 30% Load | Monthly Cost (3 tasks) |
|----------|----------------------|---------------------------|----------------------|
| 100 GB | ~2 hrs | ~6.6 hrs | $28.80 |
| 200 GB | ~4 hrs | ~13 hrs | $57.60 |
| 500 GB | ~10 hrs | ~33 hrs | $144.00 |
| 1 TB | ~20 hrs | ~66 hrs | $288.00 |

## Performance

### ECS Fargate (3 tasks × 4 vCPU 8GB ARM64)

Dual-process Apache Bench: 2 × 1M requests at 100 concurrency each.

| Metric | Value |
|--------|-------|
| Combined QPS | **21,968** |
| Total Requests | 2,000,000 |
| Failed Requests | **0** |
| p50 Latency | 6-8ms |
| p99 Latency | 31-35ms |
| ECS CPU Average | 17.7% (max 59.7%) |
| ECS Memory Average | 1.8% |

## Design Decisions

- **Why one stack per platform?** Each ad platform gets its own NLB endpoint and Kinesis stream. Independent scaling, independent failure domains, independent cost tracking.
- **Why Nginx + Lua (not Vector alone)?** Precise control over JSON serialization matching API Gateway VTL behavior. Nginx excels at handling many short-lived ad callback connections.
- **Why Vector (not direct Kinesis SDK)?** Built-in disk buffering, batching, retry logic, and backpressure — production-grade reliability without custom code.
- **Why EBS disk buffer?** Survives container restarts and Kinesis outages. Auto-reclaim prevents disk full scenarios.
- **Why existing VPC support?** Production environments already have VPCs with established networking, security groups, and VPN/peering. Creating isolated VPCs wastes IP space and complicates operations.

## Migration Strategy

1. Deploy new service writing to test Kinesis stream
2. Shadow traffic via Route 53 weighted routing (0% new)
3. Gradual cutover: 10% → 50% → 90% → 100%
4. Rollback: Route 53 weight back to 0% (TTL=60s)

## License

MIT

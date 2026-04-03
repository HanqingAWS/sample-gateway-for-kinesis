# Sample Gateway for Kinesis

A high-performance, cost-effective replacement for AWS API Gateway → Kinesis integration, using **NLB + ECS Fargate (Nginx + Vector)** architecture.

## Background

AWS API Gateway charges per million requests. For high-volume ad attribution callbacks (billions of requests/month), this becomes a significant cost. This project replaces API Gateway with a self-managed Nginx + Vector pipeline that writes directly to Kinesis, achieving **97.2% cost reduction** with **21,968 QPS** throughput and full downstream compatibility.

## Architecture

A single ECS cluster serves all ad platforms. Nginx captures the URL path, Vector dynamically routes each path to its corresponding Kinesis stream.

```
Ad Platform (GET /<platform>?account_id=xxx&click_id=xxx&...)
        |
   NLB (TCP:80) ─── single endpoint for all platforms
        |
   +── ECS Fargate Task ×3 (4vCPU, 8GB, ARM64) ──+
   |                                                |
   |  Nginx (OpenResty) :8080                       |
   |    - Parse GET query string params             |
   |    - Lua: flatten to JSON + _path metadata     |
   |    - POST JSON to Vector via localhost          |
   |    - Return HTTP 200 immediately               |
   |         |                                      |
   |         v                                      |
   |  Vector :8686                                  |
   |    - HTTP source receives JSON                 |
   |    - Route by _path → platform-specific sink   |
   |    - Clean metadata fields                     |
   |    - Disk buffer (EBS gp3, 1TB default)        |
   |    - Kinesis PutRecords (batched)              |
   |                                                |
   |  [EBS gp3: /var/lib/vector, auto-reclaim]      |
   +────────────────────────────────────────────────+
        |
        ├─ /guangdiantong → guangdiantong_kinesis_stream
        ├─ /toutiao       → toutiao_kinesis_stream
        ├─ /kuaishou      → kuaishou_kinesis_stream
        └─ /baidu         → baidu_kinesis_stream
              ↓
        Kinesis → Lambda Consumers (unchanged)
```

### Path-Based Routing

The routing from URL path to Kinesis stream is configured via the `ROUTE_MAP` environment variable, which is set at deploy time and injected into the Vector container:

```
ROUTE_MAP=/guangdiantong:gdt_stream,/toutiao:tt_stream,/kuaishou:ks_stream,/baidu:bd_stream
```

At container startup, `entrypoint.sh` dynamically generates `vector.toml` with independent route → clean → kinesis sink pipelines for each path. Unmatched paths are logged as warnings and dropped.

**Adding a new platform requires no code changes** — just add a `--route` parameter and redeploy.

## Key Features

- **Multi-platform, single cluster**: One ECS cluster serves all ad platforms via URL path routing; add platforms with `--route /path:stream`
- **Dynamic routing**: Vector config generated at startup from `ROUTE_MAP` env var — no Docker image rebuild needed to add/remove platforms
- **Existing VPC support**: Deploy into production VPC with `--vpc-id`, or auto-create a new VPC
- **Disk buffering**: EBS-backed buffer (1TB default) survives Kinesis outages; auto-reclaim when disk > 80%; 24h data retention
- **Full compatibility**: 28/28 fields match API Gateway output; all values stored as strings
- **High throughput**: 21,968 QPS on 3 Fargate tasks (4c8g ARM64), 0 failed requests
- **Low latency**: p50=6ms, p99=31ms
- **One-command deploy**: `scripts/deploy.sh` handles npm install, CDK bootstrap, image build, and deploy

## Project Structure

```
deploy/cdk/
  bin/app.ts              # CDK app entry, reads ROUTE_MAP env var
  lib/nlb-ecs-stack.ts    # Main stack: VPC/NLB/ECS/EBS/IAM/VPC Endpoints
  package.json            # CDK dependencies
docker/
  nginx/
    Dockerfile            # OpenResty 1.25.3.2 + lua-resty-http
    nginx.conf            # Worker config, init_by_lua for env vars
    collect.lua           # Query string → JSON + _path → POST to Vector
  vector/
    Dockerfile            # Vector 0.43.1 alpine + disk cleanup
    vector.toml           # Fallback config (single-stream mode)
    entrypoint.sh         # Generate vector.toml from ROUTE_MAP + disk reclaim
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

# Start with docker-compose (2 routes by default)
ROUTE_MAP="/guangdiantong:guangdiantong_attribution_event,/toutiao:toutiao_attribution_event" \
  docker-compose up --build -d

# Test different platforms
curl "http://localhost:8080/guangdiantong?account_id=123&click_id=abc"
# => {"status":"ok"}  (routed to guangdiantong_attribution_event)

curl "http://localhost:8080/toutiao?account_id=456&click_id=def"
# => {"status":"ok"}  (routed to toutiao_attribution_event)

curl "http://localhost:8080/unknown?account_id=789"
# => {"status":"ok"}  (dropped, not written to any stream)
```

## Production Deployment (CDK)

### Prerequisites

- AWS CLI configured with appropriate credentials
- Docker (for building ARM64 images)
- Node.js 18+ (CDK dependencies auto-installed by deploy script)

### Deploy All Platforms (Single Stack)

```bash
./scripts/deploy.sh \
  --stack-name AdsCallbackGateway \
  --gateway-name ads-gateway \
  --route /guangdiantong:guangdiantong_kinesis_stream \
  --route /toutiao:toutiao_kinesis_stream \
  --route /kuaishou:kuaishou_kinesis_stream \
  --route /baidu:baidu_kinesis_stream \
  --kinesis-region cn-northwest-1
```

This will:
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
  --stack-name AdsCallbackGateway \
  --gateway-name ads-gateway \
  --route /guangdiantong:guangdiantong_kinesis_stream \
  --route /toutiao:toutiao_kinesis_stream \
  --route /kuaishou:kuaishou_kinesis_stream \
  --route /baidu:baidu_kinesis_stream \
  --vpc-id vpc-0abc123def456 \
  --kinesis-region cn-northwest-1
```

The `check-vpc.sh` script validates:
- Private subnets with NAT egress (≥ 2 AZs)
- Kinesis Streams VPC Endpoint (Interface)
- ECR API + Docker VPC Endpoints (Interface)
- S3 VPC Endpoint (Gateway)
- CloudWatch Logs VPC Endpoint (Interface)
- DNS Support and DNS Hostnames enabled

If any checks fail, it outputs the exact `aws ec2 create-vpc-endpoint` commands to fix them.

### Add a New Platform

No code changes or Docker rebuild needed — just add a `--route` and redeploy:

```bash
./scripts/deploy.sh \
  --stack-name AdsCallbackGateway \
  --gateway-name ads-gateway \
  --route /guangdiantong:guangdiantong_kinesis_stream \
  --route /toutiao:toutiao_kinesis_stream \
  --route /kuaishou:kuaishou_kinesis_stream \
  --route /baidu:baidu_kinesis_stream \
  --route /unity:unity_kinesis_stream \
  --vpc-id vpc-0abc123def456 \
  --skip-build   # No image changes needed
```

CDK will:
1. Update Vector container's `ROUTE_MAP` environment variable
2. Add IAM permissions for the new Kinesis stream
3. Trigger ECS rolling deployment — new tasks generate updated Vector config at startup

### Update Existing Stack

Same command as deploy. CDK automatically detects changes and updates:

```bash
# Scale up to 5 tasks
./scripts/deploy.sh \
  --stack-name AdsCallbackGateway \
  --gateway-name ads-gateway \
  --route /guangdiantong:guangdiantong_kinesis_stream \
  --route /toutiao:toutiao_kinesis_stream \
  --ecs-count 5

# Update with code changes (rebuilds Docker images)
./scripts/deploy.sh \
  --stack-name AdsCallbackGateway \
  --gateway-name ads-gateway \
  --route /guangdiantong:guangdiantong_kinesis_stream \
  --route /toutiao:toutiao_kinesis_stream
```

### Destroy a Stack

```bash
./scripts/deploy.sh \
  --stack-name AdsCallbackGateway \
  --gateway-name ads-gateway \
  --destroy
```

### All Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--stack-name` | **Yes** | - | CloudFormation stack name (e.g., `AdsCallbackGateway`) |
| `--gateway-name` | **Yes** | - | Gateway identifier for resource naming (e.g., `ads-gateway`) |
| `--route` | **Yes** | - | Path-to-stream mapping, repeatable (e.g., `--route /guangdiantong:gdt_stream`) |
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
2. `collect.lua` extracts the URL path and all query string parameters, flattens them into a JSON object (all values as strings), and POSTs to Vector via localhost
3. **Vector** routes events by `_path` field to platform-specific sinks, cleans metadata fields, and writes to Kinesis via `PutRecords` with batching (500 events / 5MB / 1s)
4. **Disk buffer** on EBS gp3 ensures data is not lost during Kinesis outages (buffer size proportionally divided across sinks)
5. **Disk cleanup** background process auto-reclaims space when usage exceeds threshold (default: 80%), deleting data older than retention period (default: 24h)
6. Requests to **unmatched paths** return HTTP 200 to the client but are logged as warnings and dropped (not written to any stream)

## Cost Comparison (cn-northwest-1, 4 platforms, 259.2B requests/month)

| Solution | Monthly Cost |
|----------|-------------|
| API Gateway REST API (4 platforms combined) | **¥490,861** |
| NLB + ECS Fargate (1 cluster, 3 tasks × 4c8g ARM64) | **¥13,609** |
| **Saving** | **¥477,252 (97.2%)** |

ECS cost breakdown: Fargate ¥3,939 + NLB ¥4,082 + EBS 3×1TB gp3 ¥1,377 + VPC Endpoint (Kinesis) ¥4,211

> 1 ECS cluster serves all 4 platforms. ECS cost is fixed regardless of request volume.

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

- **Why single cluster with path routing?** One ECS cluster handles all platforms. Adding a platform is a config change, not new infrastructure. Cost is fixed at ¥13,609/month regardless of how many platforms or requests.
- **Why dynamic Vector config?** `entrypoint.sh` generates `vector.toml` from `ROUTE_MAP` env var at startup. No Docker image rebuild when adding/removing platforms — just redeploy the CDK stack.
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

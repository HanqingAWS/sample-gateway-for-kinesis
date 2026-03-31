# Sample Gateway for Kinesis

A high-performance, cost-effective replacement for AWS API Gateway → Kinesis integration, using **NLB + ECS Fargate (Nginx + Vector)** architecture.

## Background

AWS API Gateway charges $3.50 per million requests. For high-volume ad attribution callbacks (100M+ requests/month), this becomes a significant cost. This project replaces API Gateway with a self-managed Nginx + Vector pipeline that writes directly to Kinesis, achieving **~67% cost reduction** with **21,968 QPS** throughput and full downstream compatibility.

## Architecture

```
Ad Platform (GET /guangdiantong?account_id=xxx&click_id=xxx&...)
        |
   NLB (TCP:80)
        |
   +--- ECS Fargate Task -----------------------------------+
   |                                                         |
   |  Nginx (OpenResty) :8080                                |
   |    - Parse GET query string params                      |
   |    - Lua: flatten to JSON (all values as strings)       |
   |    - POST JSON to Vector                                |
   |    - Return HTTP 200 immediately                        |
   |         |                                               |
   |         v                                               |
   |  Vector :8686                                           |
   |    - HTTP source receives JSON                          |
   |    - Route transform: path -> Kinesis stream            |
   |    - Disk buffer (EBS, disaster recovery)               |
   |    - Kinesis PutRecords (batched)                       |
   |                                                         |
   |  [EBS Volume: /var/lib/vector, gp3]                     |
   +---------------------------------------------------------+
        |
   Kinesis Streams -> Lambda Consumers (unchanged)
```

## Key Features

- **Multi-stream routing**: Different URL paths (`/guangdiantong`, `/toutiao`, etc.) route to different Kinesis streams via Vector transforms
- **Disk buffering**: EBS-backed buffer survives Kinesis outages; `when_full: block` provides backpressure
- **Full compatibility**: 28/28 fields match API Gateway output; all values stored as strings, JSON arrays as string literals
- **High throughput**: 21,968 QPS on 3 Fargate tasks (4c8g ARM64), ~5K QPS per task
- **Low latency**: p50=6ms, p99=31ms; Nginx returns HTTP 200 immediately without waiting for Kinesis write
- **CDK infrastructure**: Single `npx cdk deploy` creates all 49 AWS resources

## Project Structure

```
deploy/
  cdk/
    bin/app.ts          # CDK app entry point
    lib/nlb-ecs-stack.ts # Main stack: VPC, NLB, ECS, EBS, IAM, VPC Endpoints
    package.json        # CDK dependencies
    tsconfig.json       # TypeScript config
    cdk.json            # CDK config
docker/
  nginx/
    Dockerfile          # OpenResty 1.25.3.2 + lua-resty-http v0.17.2
    nginx.conf          # Worker config, init_by_lua for env vars
    collect.lua         # Query string -> JSON -> POST to Vector
  vector/
    Dockerfile          # Vector 0.43.1 alpine
    vector.toml         # HTTP source -> route -> clean -> Kinesis sinks
scripts/
  build-and-push.sh     # Build ARM64 images, push to ECR
docker-compose.yml      # Local/EC2 development setup
test-report.html        # Comprehensive test & performance report
```

## Quick Start

### Prerequisites

- Docker & Docker Compose
- AWS credentials with Kinesis access (IAM role or env vars)

### Run Locally

```bash
# Clone the repo
git clone https://github.com/HanqingAWS/sample-gateway-for-kinesis.git
cd sample-gateway-for-kinesis

# Start services
docker-compose up --build -d

# Test (replace with your Kinesis stream config)
curl "http://localhost:8080/test?account_id=123&click_id=abc"
# => {"status":"ok"}
```

### Environment Variables

Configure Kinesis streams in `docker-compose.yml` or pass as environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `KINESIS_REGION` | AWS region | `ap-northeast-1` |
| `KINESIS_STREAM_GUANGDIANTONG` | Tencent Ads stream | `guangdiantong_kinesis_stream` |
| `KINESIS_STREAM_TOUTIAO` | ByteDance stream | `toutiao_kinesis_stream` |
| `KINESIS_STREAM_TEST` | Test stream | `guangdiantong_attribution_event` |
| `VPC_CIDR` | VPC CIDR block (CDK only) | `10.0.0.0/16` |
| `ECS_DESIRED_COUNT` | Number of Fargate tasks | `3` |
| `EBS_SIZE_GB` | EBS volume size per task | `50` |

## How It Works

1. **Nginx (OpenResty + Lua)** receives GET requests on port 8080
2. `collect.lua` extracts all query string parameters, flattens them into a JSON object (all values as strings), and POSTs to Vector
3. **Vector** receives the JSON, routes by URL path to the correct Kinesis stream, and writes via `PutRecords` with batching (500 events / 5MB / 1s)
4. **Disk buffer** on EBS ensures data is not lost during Kinesis outages

### Adding a New Stream

1. Add a route condition in `vector.toml`:
   ```toml
   [transforms.route_by_path.route]
   new_platform = '._route_path == "/new_platform"'
   ```
2. Add clean transform and Kinesis sink (copy existing pattern)
3. Add `KINESIS_STREAM_NEW_PLATFORM` environment variable
4. Redeploy

## Cost Comparison (100M requests/month)

| Component | API Gateway | NLB + ECS Fargate |
|-----------|-------------|-------------------|
| Request handling | $350 | NLB ~$16 |
| Compute | included | Fargate 3×4c8g ARM ~$87 |
| Storage | - | EBS 3×50GB gp3 ~$12 |
| **Total** | **~$350/mo** | **~$115/mo (67% saving)** |

At 1B requests/month: API Gateway = $3,500 vs NLB+ECS = ~$115 (97% saving). Cost is fixed regardless of request volume.

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

### EC2 Single-Node Baseline (t4g.xlarge, docker-compose)

| Concurrency | QPS | p50 | p99 |
|-------------|-----|-----|-----|
| 100 | 4,922 | 19ms | 48ms |
| 200 | 5,120 | 36ms | 91ms |

## Design Decisions

- **Why Nginx + Lua (not Vector alone)?** Precise control over JSON serialization matching API Gateway VTL behavior. Nginx excels at handling many short-lived ad callback connections.
- **Why Vector (not direct Kinesis SDK)?** Built-in disk buffering, batching, retry logic, and backpressure — production-grade reliability without custom code.
- **Why EBS disk buffer?** Survives container restarts and Kinesis outages. 1TB gp3 can buffer ~15-50 hours of traffic depending on load.
- **Why random partition keys?** Ensures even shard distribution. API Gateway used `$context.requestId` which is also effectively random.

## Production Deployment (CDK)

Infrastructure defined in TypeScript CDK (`deploy/cdk/`). Deploys 49 AWS resources:

```bash
cd deploy/cdk
npm install
npx cdk bootstrap   # First time only
npx cdk deploy       # Creates all resources
```

Resources created:
- **VPC** with 2 AZ, public/private subnets, 1 NAT Gateway
- **VPC Endpoints**: Kinesis Streams, ECR, S3, CloudWatch Logs (avoid NAT costs)
- **NLB** (internet-facing, TCP:80, cross-zone)
- **ECS Fargate** (3 tasks × 4 vCPU 8GB ARM64, auto-scaling 3-10)
- **EBS gp3** volumes for Vector disk buffer (per task)
- **ECR** repositories for Nginx and Vector images
- **IAM** roles with least-privilege Kinesis access

### Build & Push Docker Images

```bash
./scripts/build-and-push.sh [REGION] [ACCOUNT_ID]
```

## Migration Strategy

1. Deploy new service writing to test Kinesis stream
2. Shadow traffic via Route 53 weighted routing (0% new)
3. Gradual cutover: 10% → 50% → 90% → 100%
4. Rollback: Route 53 weight back to 0% (TTL=60s)

## License

MIT

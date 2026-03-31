# Sample Gateway for Kinesis

A high-performance, cost-effective replacement for AWS API Gateway → Kinesis integration, using **NLB + ECS (Nginx + Vector)** architecture.

## Background

AWS API Gateway charges $3.50 per million requests. For high-volume ad attribution callbacks (100M+ requests/month), this becomes a significant cost. This project replaces API Gateway with a self-managed Nginx + Vector pipeline that writes directly to Kinesis, achieving **~57% cost reduction** while maintaining full downstream compatibility.

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
- **Full compatibility**: 30/30 fields match API Gateway output; all values stored as strings, JSON arrays as string literals
- **High throughput**: ~5,000+ QPS on a single t4g.xlarge node (200 concurrent connections)
- **Low latency**: Nginx returns HTTP 200 immediately without waiting for Kinesis write

## Project Structure

```
docker/
  nginx/
    Dockerfile          # OpenResty 1.25.3.2 + lua-resty-http v0.17.2
    nginx.conf          # Worker config, Docker DNS resolver
    collect.lua         # Query string -> JSON -> POST to Vector
  vector/
    Dockerfile          # Vector 0.43.1 alpine
    vector.toml         # HTTP source -> route -> clean -> Kinesis sinks
docker-compose.yml      # Local/EC2 development setup
test-report.html        # Comprehensive test & compatibility report
CLAUDE.md               # Project notes & test data
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

| Variable | Description | Example |
|----------|-------------|---------|
| `KINESIS_REGION` | AWS region | `ap-northeast-1` |
| `KINESIS_STREAM_GUANGDIANTONG` | Tencent Ads stream | `guangdiantong_kinesis_stream` |
| `KINESIS_STREAM_TOUTIAO` | ByteDance stream | `toutiao_kinesis_stream` |
| `KINESIS_STREAM_TEST` | Test stream | `guangdiantong_attribution_event` |

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

| Component | API Gateway | NLB + ECS (Nginx+Vector) |
|-----------|-------------|--------------------------|
| Request handling | $350 | NLB ~$10 |
| Compute | included | Fargate 2 tasks ~$60 |
| Storage | - | EBS gp3 ~$16-80 |
| **Total** | **~$350/mo** | **~$86-150/mo** |

## Performance

Tested on EC2 t4g.xlarge (ARM/Graviton) with full 28-field ad attribution payloads:

| Concurrency | QPS | Avg Latency |
|-------------|-----|-------------|
| 50 | ~4,922 | ~10ms |
| 100 | ~5,058 | ~20ms |
| 200 | ~5,120 | ~39ms |

## Design Decisions

- **Why Nginx + Lua (not Vector alone)?** Precise control over JSON serialization matching API Gateway VTL behavior. Nginx excels at handling many short-lived ad callback connections.
- **Why Vector (not direct Kinesis SDK)?** Built-in disk buffering, batching, retry logic, and backpressure — production-grade reliability without custom code.
- **Why EBS disk buffer?** Survives container restarts and Kinesis outages. 1TB gp3 can buffer ~15-50 hours of traffic depending on load.
- **Why random partition keys?** Ensures even shard distribution. API Gateway used `$context.requestId` which is also effectively random.

## Production Deployment

Infrastructure is designed for CDK TypeScript deployment:
- NLB (internet-facing, TCP:80) → ECS Fargate (auto-scaling 2-10 tasks)
- EBS gp3 volume mounted to Vector container
- Kinesis VPC Endpoint to avoid NAT costs
- CloudWatch Logs for observability

## Migration Strategy

1. Deploy new service writing to test Kinesis stream
2. Shadow traffic via Route 53 weighted routing (0% new)
3. Gradual cutover: 10% → 50% → 90% → 100%
4. Rollback: Route 53 weight back to 0% (TTL=60s)

## License

MIT

#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { NlbEcsStack } from '../lib/nlb-ecs-stack';

const app = new cdk.App();

const stackName = process.env.STACK_NAME || 'AdsCallbackGatewayStack';
const gatewayName = process.env.GATEWAY_NAME || 'ads-gateway';
const kinesisRegion = process.env.KINESIS_REGION || 'ap-northeast-1';

// Parse ROUTE_MAP: /path1:stream1,/path2:stream2,...
// Fallback: single-stream mode via KINESIS_STREAM_NAME (backward compatible)
function parseRouteMap(): Record<string, string> {
  const routeMapStr = process.env.ROUTE_MAP || '';
  if (routeMapStr) {
    const map: Record<string, string> = {};
    for (const entry of routeMapStr.split(',')) {
      const [path, stream] = entry.split(':');
      if (path && stream) {
        map[path] = stream;
      }
    }
    return map;
  }

  // Backward compatible: single stream
  const stream = process.env.KINESIS_STREAM_NAME;
  if (stream) {
    const platform = process.env.PLATFORM_NAME || 'default';
    return { [`/${platform}`]: stream };
  }

  throw new Error('Either ROUTE_MAP or KINESIS_STREAM_NAME must be set');
}

new NlbEcsStack(app, stackName, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || kinesisRegion,
  },
  description: `NLB + ECS (Nginx + Vector) -> Kinesis multi-stream gateway`,
  gatewayName,
  routeMap: parseRouteMap(),
  kinesisRegion,
  vpcId: process.env.VPC_ID || undefined,
  vpcCidr: process.env.VPC_CIDR || '10.0.0.0/16',
  ecsDesiredCount: parseInt(process.env.ECS_DESIRED_COUNT || '3', 10),
  ebsSizeGb: parseInt(process.env.EBS_SIZE_GB || '1000', 10),
  ebsRetentionHours: parseInt(process.env.EBS_RETENTION_HOURS || '24', 10),
  ebsReclaimPercent: parseInt(process.env.EBS_RECLAIM_PERCENT || '80', 10),
});

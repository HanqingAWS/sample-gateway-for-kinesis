#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { NlbEcsStack } from '../lib/nlb-ecs-stack';

const app = new cdk.App();

const stackName = process.env.STACK_NAME || 'AdsCallbackGatewayStack';
const platformName = process.env.PLATFORM_NAME || 'ads-callback';
const kinesisRegion = process.env.KINESIS_REGION || 'ap-northeast-1';

new NlbEcsStack(app, stackName, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || kinesisRegion,
  },
  description: `NLB + ECS (Nginx + Vector) -> Kinesis gateway for ${platformName}`,
  platformName,
  kinesisStreamName: process.env.KINESIS_STREAM_NAME || 'guangdiantong_attribution_event',
  kinesisRegion,
  vpcId: process.env.VPC_ID || undefined,
  vpcCidr: process.env.VPC_CIDR || '10.0.0.0/16',
  ecsDesiredCount: parseInt(process.env.ECS_DESIRED_COUNT || '3', 10),
  ebsSizeGb: parseInt(process.env.EBS_SIZE_GB || '1000', 10),
  ebsRetentionHours: parseInt(process.env.EBS_RETENTION_HOURS || '24', 10),
  ebsReclaimPercent: parseInt(process.env.EBS_RECLAIM_PERCENT || '80', 10),
});

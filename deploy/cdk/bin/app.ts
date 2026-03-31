#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { NlbEcsStack } from '../lib/nlb-ecs-stack';

const app = new cdk.App();

new NlbEcsStack(app, 'AdsCallbackGatewayStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || 'ap-northeast-1',
  },
  description: 'NLB + ECS (Nginx + Vector) -> Kinesis ad attribution callback gateway',
});

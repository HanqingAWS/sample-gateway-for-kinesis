import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as autoscaling from 'aws-cdk-lib/aws-applicationautoscaling';
import { Construct } from 'constructs';

export class NlbEcsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ────────────────────────────────────────────
    // Configuration from environment variables
    // ────────────────────────────────────────────
    const vpcCidr = process.env.VPC_CIDR || '10.0.0.0/16';
    const kinesisRegion = process.env.KINESIS_REGION || 'ap-northeast-1';
    const streamGuangdiantong = process.env.KINESIS_STREAM_GUANGDIANTONG || 'guangdiantong_kinesis_stream';
    const streamToutiao = process.env.KINESIS_STREAM_TOUTIAO || 'toutiao_kinesis_stream';
    const streamTest = process.env.KINESIS_STREAM_TEST || 'guangdiantong_attribution_event';
    const desiredCount = parseInt(process.env.ECS_DESIRED_COUNT || '3', 10);
    const ebsSizeGb = parseInt(process.env.EBS_SIZE_GB || '50', 10);

    // ────────────────────────────────────────────
    // VPC
    // ────────────────────────────────────────────
    const vpc = new ec2.Vpc(this, 'GatewayVpc', {
      ipAddresses: ec2.IpAddresses.cidr(vpcCidr),
      maxAzs: 2,
      natGateways: 1,
      subnetConfiguration: [
        {
          cidrMask: 24,
          name: 'Public',
          subnetType: ec2.SubnetType.PUBLIC,
        },
        {
          cidrMask: 24,
          name: 'Private',
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
        },
      ],
    });

    // Kinesis VPC Endpoint (Interface type) to avoid NAT costs for Kinesis traffic
    vpc.addInterfaceEndpoint('KinesisEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.KINESIS_STREAMS,
    });

    // ECR VPC Endpoints for image pull without NAT
    vpc.addInterfaceEndpoint('EcrEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.ECR,
    });
    vpc.addInterfaceEndpoint('EcrDockerEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.ECR_DOCKER,
    });
    vpc.addGatewayEndpoint('S3Endpoint', {
      service: ec2.GatewayVpcEndpointAwsService.S3,
    });

    // CloudWatch Logs VPC Endpoint
    vpc.addInterfaceEndpoint('CloudWatchLogsEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.CLOUDWATCH_LOGS,
    });

    // ────────────────────────────────────────────
    // ECR Repositories
    // ────────────────────────────────────────────
    const nginxRepo = new ecr.Repository(this, 'NginxRepo', {
      repositoryName: 'ads-callback-nginx',
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      emptyOnDelete: true,
    });

    const vectorRepo = new ecr.Repository(this, 'VectorRepo', {
      repositoryName: 'ads-callback-vector',
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      emptyOnDelete: true,
    });

    // ────────────────────────────────────────────
    // ECS Cluster
    // ────────────────────────────────────────────
    const cluster = new ecs.Cluster(this, 'GatewayCluster', {
      vpc,
      clusterName: 'ads-callback-gateway',
      containerInsights: true,
    });

    // ────────────────────────────────────────────
    // CloudWatch Log Group
    // ────────────────────────────────────────────
    const logGroup = new logs.LogGroup(this, 'GatewayLogGroup', {
      logGroupName: '/ecs/ads-callback-gateway',
      retention: logs.RetentionDays.TWO_WEEKS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ────────────────────────────────────────────
    // Task Definition (4 vCPU, 8 GB)
    // ────────────────────────────────────────────
    const taskDef = new ecs.FargateTaskDefinition(this, 'GatewayTaskDef', {
      memoryLimitMiB: 8192,
      cpu: 4096,
      family: 'ads-callback-gateway',
      runtimePlatform: {
        operatingSystemFamily: ecs.OperatingSystemFamily.LINUX,
        cpuArchitecture: ecs.CpuArchitecture.ARM64,
      },
    });

    // Task Role: Kinesis access
    taskDef.taskRole.addToPrincipalPolicy(new iam.PolicyStatement({
      actions: [
        'kinesis:PutRecords',
        'kinesis:PutRecord',
        'kinesis:DescribeStream',
        'kinesis:DescribeStreamSummary',
        'kinesis:ListShards',
      ],
      resources: [
        `arn:aws:kinesis:${kinesisRegion}:${this.account}:stream/${streamGuangdiantong}`,
        `arn:aws:kinesis:${kinesisRegion}:${this.account}:stream/${streamToutiao}`,
        `arn:aws:kinesis:${kinesisRegion}:${this.account}:stream/${streamTest}`,
      ],
    }));

    // EBS Volume for Vector disk buffer (managed by ECS)
    const volume = new ecs.ServiceManagedVolume(this, 'VectorDataVolume', {
      name: 'vector-data',
      managedEBSVolume: {
        size: cdk.Size.gibibytes(ebsSizeGb),
        volumeType: ec2.EbsDeviceVolumeType.GP3,
        fileSystemType: ecs.FileSystemType.EXT4,
        tagSpecifications: [{
          tags: {
            Name: 'ads-callback-vector-data',
          },
          propagateTags: ecs.EbsPropagatedTagSource.SERVICE,
        }],
      },
    });
    taskDef.addVolume(volume);

    // Nginx container (1 vCPU, 2 GB)
    const nginxContainer = taskDef.addContainer('nginx', {
      image: ecs.ContainerImage.fromEcrRepository(nginxRepo, 'latest'),
      cpu: 1024,
      memoryLimitMiB: 2048,
      essential: true,
      logging: ecs.LogDrivers.awsLogs({
        logGroup,
        streamPrefix: 'nginx',
      }),
      environment: {
        VECTOR_HOST: '127.0.0.1',
        VECTOR_PORT: '8686',
      },
      portMappings: [
        { containerPort: 8080, protocol: ecs.Protocol.TCP },
      ],
    });

    // Vector container (3 vCPU, 6 GB)
    const vectorContainer = taskDef.addContainer('vector', {
      image: ecs.ContainerImage.fromEcrRepository(vectorRepo, 'latest'),
      cpu: 3072,
      memoryLimitMiB: 6144,
      essential: true,
      logging: ecs.LogDrivers.awsLogs({
        logGroup,
        streamPrefix: 'vector',
      }),
      environment: {
        KINESIS_REGION: kinesisRegion,
        KINESIS_STREAM_GUANGDIANTONG: streamGuangdiantong,
        KINESIS_STREAM_TOUTIAO: streamToutiao,
        KINESIS_STREAM_TEST: streamTest,
        AWS_REGION: kinesisRegion,
        VECTOR_LOG: 'info',
      },
      portMappings: [
        { containerPort: 8686, protocol: ecs.Protocol.TCP },
      ],
    });

    // Mount EBS volume to Vector container
    volume.mountIn(vectorContainer, {
      containerPath: '/var/lib/vector',
      readOnly: false,
    });

    // ────────────────────────────────────────────
    // Security Group
    // ────────────────────────────────────────────
    const serviceSg = new ec2.SecurityGroup(this, 'ServiceSg', {
      vpc,
      description: 'Security group for ads callback gateway ECS tasks',
      allowAllOutbound: true,
    });
    serviceSg.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(8080), 'NLB health check and traffic');

    // ────────────────────────────────────────────
    // NLB
    // ────────────────────────────────────────────
    const nlb = new elbv2.NetworkLoadBalancer(this, 'GatewayNlb', {
      vpc,
      internetFacing: true,
      crossZoneEnabled: true,
      loadBalancerName: 'ads-callback-nlb',
    });

    // ────────────────────────────────────────────
    // ECS Service
    // ────────────────────────────────────────────
    const service = new ecs.FargateService(this, 'GatewayService', {
      cluster,
      taskDefinition: taskDef,
      desiredCount,
      securityGroups: [serviceSg],
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      assignPublicIp: false,
      circuitBreaker: { enable: true, rollback: true },
      healthCheckGracePeriod: cdk.Duration.seconds(60),
      serviceName: 'ads-callback-gateway',
    });

    // Attach the managed EBS volume to the service
    service.addVolume(volume);

    // ────────────────────────────────────────────
    // NLB Target Group + Listener
    // ────────────────────────────────────────────
    const targetGroup = new elbv2.NetworkTargetGroup(this, 'GatewayTargetGroup', {
      vpc,
      port: 8080,
      protocol: elbv2.Protocol.TCP,
      targetType: elbv2.TargetType.IP,
      healthCheck: {
        enabled: true,
        protocol: elbv2.Protocol.HTTP,
        path: '/health',
        interval: cdk.Duration.seconds(10),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 2,
      },
      deregistrationDelay: cdk.Duration.seconds(30),
    });

    service.attachToNetworkTargetGroup(targetGroup);

    nlb.addListener('TcpListener', {
      port: 80,
      defaultTargetGroups: [targetGroup],
    });

    // ────────────────────────────────────────────
    // Auto-scaling: CPU 70% target tracking
    // ────────────────────────────────────────────
    const scaling = service.autoScaleTaskCount({
      minCapacity: desiredCount,
      maxCapacity: 10,
    });

    scaling.scaleOnCpuUtilization('CpuScaling', {
      targetUtilizationPercent: 70,
      scaleInCooldown: cdk.Duration.seconds(300),
      scaleOutCooldown: cdk.Duration.seconds(60),
    });

    // ────────────────────────────────────────────
    // Outputs
    // ────────────────────────────────────────────
    new cdk.CfnOutput(this, 'NlbDns', {
      value: nlb.loadBalancerDnsName,
      description: 'NLB DNS name for ad platform callbacks',
      exportName: 'AdsCallbackNlbDns',
    });

    new cdk.CfnOutput(this, 'NginxEcrUri', {
      value: nginxRepo.repositoryUri,
      description: 'Nginx ECR repository URI',
    });

    new cdk.CfnOutput(this, 'VectorEcrUri', {
      value: vectorRepo.repositoryUri,
      description: 'Vector ECR repository URI',
    });

    new cdk.CfnOutput(this, 'ClusterName', {
      value: cluster.clusterName,
      description: 'ECS cluster name',
    });

    new cdk.CfnOutput(this, 'ServiceName', {
      value: service.serviceName,
      description: 'ECS service name',
    });
  }
}

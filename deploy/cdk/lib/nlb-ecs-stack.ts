import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';

export interface NlbEcsStackProps extends cdk.StackProps {
  platformName: string;
  kinesisStreamName: string;
  kinesisRegion: string;
  vpcId?: string;
  vpcCidr?: string;
  ecsDesiredCount: number;
  ebsSizeGb: number;
  ebsRetentionHours: number;
  ebsReclaimPercent: number;
}

export class NlbEcsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: NlbEcsStackProps) {
    super(scope, id, props);

    const {
      platformName,
      kinesisStreamName,
      kinesisRegion,
      vpcId,
      vpcCidr,
      ecsDesiredCount,
      ebsSizeGb,
      ebsRetentionHours,
      ebsReclaimPercent,
    } = props;

    // ────────────────────────────────────────────
    // VPC: import existing or create new
    // ────────────────────────────────────────────
    let vpc: ec2.IVpc;

    if (vpcId) {
      // Import existing VPC — assumes it already has required subnets and VPC endpoints
      // Run scripts/check-vpc.sh to validate before deploying
      vpc = ec2.Vpc.fromLookup(this, 'ImportedVpc', { vpcId });
    } else {
      // Create new VPC with all required endpoints
      const newVpc = new ec2.Vpc(this, 'GatewayVpc', {
        ipAddresses: ec2.IpAddresses.cidr(vpcCidr || '10.0.0.0/16'),
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

      // VPC Endpoints
      newVpc.addInterfaceEndpoint('KinesisEndpoint', {
        service: ec2.InterfaceVpcEndpointAwsService.KINESIS_STREAMS,
      });
      newVpc.addInterfaceEndpoint('EcrEndpoint', {
        service: ec2.InterfaceVpcEndpointAwsService.ECR,
      });
      newVpc.addInterfaceEndpoint('EcrDockerEndpoint', {
        service: ec2.InterfaceVpcEndpointAwsService.ECR_DOCKER,
      });
      newVpc.addGatewayEndpoint('S3Endpoint', {
        service: ec2.GatewayVpcEndpointAwsService.S3,
      });
      newVpc.addInterfaceEndpoint('CloudWatchLogsEndpoint', {
        service: ec2.InterfaceVpcEndpointAwsService.CLOUDWATCH_LOGS,
      });

      vpc = newVpc;
    }

    // ────────────────────────────────────────────
    // ECR Repositories
    // ────────────────────────────────────────────
    const nginxRepo = new ecr.Repository(this, 'NginxRepo', {
      repositoryName: `${platformName}-nginx`,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      emptyOnDelete: true,
    });

    const vectorRepo = new ecr.Repository(this, 'VectorRepo', {
      repositoryName: `${platformName}-vector`,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      emptyOnDelete: true,
    });

    // ────────────────────────────────────────────
    // ECS Cluster
    // ────────────────────────────────────────────
    const cluster = new ecs.Cluster(this, 'GatewayCluster', {
      vpc,
      clusterName: `${platformName}-gateway`,
      containerInsights: true,
    });

    // ────────────────────────────────────────────
    // CloudWatch Log Group
    // ────────────────────────────────────────────
    const logGroup = new logs.LogGroup(this, 'GatewayLogGroup', {
      logGroupName: `/ecs/${platformName}-gateway`,
      retention: logs.RetentionDays.TWO_WEEKS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ────────────────────────────────────────────
    // Task Definition (4 vCPU, 8 GB)
    // ────────────────────────────────────────────
    const taskDef = new ecs.FargateTaskDefinition(this, 'GatewayTaskDef', {
      memoryLimitMiB: 8192,
      cpu: 4096,
      family: `${platformName}-gateway`,
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
        `arn:aws:kinesis:${kinesisRegion}:${this.account}:stream/${kinesisStreamName}`,
      ],
    }));

    // EBS Volume for Vector disk buffer
    const volume = new ecs.ServiceManagedVolume(this, 'VectorDataVolume', {
      name: 'vector-data',
      managedEBSVolume: {
        size: cdk.Size.gibibytes(ebsSizeGb),
        volumeType: ec2.EbsDeviceVolumeType.GP3,
        fileSystemType: ecs.FileSystemType.EXT4,
        tagSpecifications: [{
          tags: {
            Name: `${platformName}-vector-data`,
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
        KINESIS_STREAM_NAME: kinesisStreamName,
        AWS_REGION: kinesisRegion,
        VECTOR_LOG: 'info',
        EBS_RETENTION_HOURS: String(ebsRetentionHours),
        EBS_RECLAIM_PERCENT: String(ebsReclaimPercent),
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
      description: `Security group for ${platformName} gateway ECS tasks`,
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
      loadBalancerName: `${platformName}-nlb`,
    });

    // ────────────────────────────────────────────
    // ECS Service
    // ────────────────────────────────────────────
    const service = new ecs.FargateService(this, 'GatewayService', {
      cluster,
      taskDefinition: taskDef,
      desiredCount: ecsDesiredCount,
      securityGroups: [serviceSg],
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      assignPublicIp: false,
      circuitBreaker: { enable: true, rollback: true },
      healthCheckGracePeriod: cdk.Duration.seconds(60),
      serviceName: `${platformName}-gateway`,
    });

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
      minCapacity: ecsDesiredCount,
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
      description: `${platformName} NLB DNS`,
      exportName: `${platformName}-NlbDns`,
    });

    new cdk.CfnOutput(this, 'NginxEcrUri', {
      value: nginxRepo.repositoryUri,
      description: `${platformName} Nginx ECR URI`,
    });

    new cdk.CfnOutput(this, 'VectorEcrUri', {
      value: vectorRepo.repositoryUri,
      description: `${platformName} Vector ECR URI`,
    });

    new cdk.CfnOutput(this, 'ClusterName', {
      value: cluster.clusterName,
    });

    new cdk.CfnOutput(this, 'ServiceName', {
      value: service.serviceName,
    });
  }
}

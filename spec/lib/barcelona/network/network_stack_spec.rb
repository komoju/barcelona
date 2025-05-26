require "rails_helper"

describe Barcelona::Network::NetworkStack do
  let(:district) { create :district }

  it "generates network stack CF template" do
    district.nat_type = nil
    stack = described_class.new(district)
    generated = JSON.load(stack.target!)
    expect(generated["Description"]).to eq "AWS CloudFormation for Barcelona #{stack.name}"
    expect(generated["AWSTemplateFormatVersion"]).to eq "2010-09-09"
    expected = {
      "VPC" => {
        "Type" => "AWS::EC2::VPC",
        "Properties" =>
        {
          "CidrBlock" => district.cidr_block,
          "EnableDnsSupport" => true,
          "EnableDnsHostnames" => true,
          "Tags" =>
          [{"Key" => "Name", "Value" => {"Ref" => "AWS::StackName"}},
           {"Key" => "barcelona", "Value" => district.name}]}},
      "InternetGateway" => {
        "Type" => "AWS::EC2::InternetGateway",
        "Properties" => {
          "Tags" =>
          [{"Key" => "Name", "Value" => {"Ref" => "AWS::StackName"}},
           {"Key" => "barcelona", "Value" => district.name},
           {"Key" => "Network", "Value" => "Public"}]}},
      "VPCGatewayAttachment" => {
        "Type" => "AWS::EC2::VPCGatewayAttachment",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "InternetGatewayId" => {"Ref" => "InternetGateway"}}},
      "VPCDHCPOptions" => {
        "Type" => "AWS::EC2::DHCPOptions",
        "Properties" => {
          "DomainName" => {
            "Fn::Join" => [" ", ["us-east-1.compute.internal", "bcn"]]},
          "DomainNameServers" => ["AmazonProvidedDNS"]}},
      "VPCDHCPOptionsAssociation" => {
        "Type" => "AWS::EC2::VPCDHCPOptionsAssociation",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "DhcpOptionsId" => {"Ref" => "VPCDHCPOptions"}}},
      "LocalHostedZone" => {
        "Type" => "AWS::Route53::HostedZone",
        "Properties" => {
          "Name" => "bcn",
          "VPCs" => [{"VPCId" => {"Ref" => "VPC"}, "VPCRegion" => {"Ref" => "AWS::Region"}}]}},
      "PublicELBSecurityGroup" => {
        "Type" => "AWS::EC2::SecurityGroup",
        "Properties" => {
          "GroupDescription" => "SG for Public ELB",
          "VpcId" => {"Ref" => "VPC"},
          "SecurityGroupIngress" => [
            {"IpProtocol" => "tcp",
             "FromPort" => 80,
             "ToPort" => 80,
             "CidrIp" => "0.0.0.0/0"},
            {"IpProtocol" => "tcp",
             "FromPort" => 443,
             "ToPort" => 443,
             "CidrIp" => "0.0.0.0/0"},
            {"IpProtocol" => "-1",
             "FromPort" => "-1",
             "ToPort" => "-1",
             "CidrIp" => district.cidr_block}],
          "Tags" => [{"Key" => "barcelona", "Value" => district.name}],
        }
      },
      "PublicELBSecurityGroupEgress" => {
        "Type" => "AWS::EC2::SecurityGroupEgress",
        "Properties" => {
          "GroupId" => {"Ref" => "PublicELBSecurityGroup"},
          "IpProtocol" => "tcp",
          "FromPort" => 1,
          "ToPort" => 65535,
          "SourceSecurityGroupId" => {"Ref" => "InstanceSecurityGroup"}
        }
      },
      "PrivateELBSecurityGroup" => {
        "Type" => "AWS::EC2::SecurityGroup",
        "Properties" => {"GroupDescription" => "SG for Private ELB",
                         "VpcId" => {"Ref" => "VPC"},
                         "SecurityGroupIngress" => [
                           {"IpProtocol" => "tcp",
                            "FromPort" => 1,
                            "ToPort" => 65535,
                            "CidrIp" => district.cidr_block}],
                          "Tags" => [{"Key" => "barcelona", "Value" => district.name}],
                        }
      },
      "PrivateELBSecurityGroupEgress" => {
        "Type" => "AWS::EC2::SecurityGroupEgress",
        "Properties" => {
          "GroupId" => {"Ref" => "PrivateELBSecurityGroup"},
          "IpProtocol" => "tcp",
          "FromPort" => 1,
          "ToPort" => 65535,
          "SourceSecurityGroupId" => {"Ref" => "InstanceSecurityGroup"}
        }
      },
      "ContainerInstanceAccessibleSecurityGroup" => {
        "Type" => "AWS::EC2::SecurityGroup",
        "Properties" => {
          "GroupDescription" => "accessible to container instances",
          "VpcId" => {"Ref" => "VPC"},
          "Tags" => [{"Key" => "barcelona", "Value" => district.name}]
        }
      },
      "ContainerInstanceAutoScalingGroup" => {
        "Type"=>"AWS::AutoScaling::AutoScalingGroup",
        "Properties" => {
          "DesiredCapacity" => 1,
          "Cooldown" => 0,
          "HealthCheckGracePeriod" => 0,
          "MaxSize" => 3,
          "MinSize" => 1,
          "HealthCheckType" => "EC2",
          "LaunchConfigurationName" => {"Ref" => "ContainerInstanceLaunchConfiguration"},
          "VPCZoneIdentifier"=>[
            {"Ref" => "SubnetTrusted1"},
            {"Ref"=>"SubnetTrusted2"}
          ],
          "Tags" => [
            {"Key"=>"Name", "Value"=>"barcelona-container-instance", "PropagateAtLaunch"=>true},
            {"Key"=>"barcelona", "Value"=>district.name, "PropagateAtLaunch"=>true},
            {"Key"=>"barcelona-role", "Value"=>"ci", "PropagateAtLaunch"=>true}
          ]
        },
        "UpdatePolicy" => {
          "AutoScalingRollingUpdate" => {
            "MaxBatchSize" => 20,
            "MinInstancesInService" => 1
          }
        }
      },
      "ContainerInstanceLaunchConfiguration" => {
        "Type" => "AWS::AutoScaling::LaunchConfiguration",
        "Properties" => {
          "IamInstanceProfile" => {"Ref"=>"ECSInstanceProfile"},
          "ImageId" => kind_of(String),
          "InstanceType" => "t3.small",
          "MetadataOptions"=>{"HttpTokens"=>"required"},
          "SecurityGroups" => [{"Ref"=>"InstanceSecurityGroup"}],
          "UserData" => instance_of(String),
          "EbsOptimized" => true,
          "BlockDeviceMappings" => [
            {
              "DeviceName" => "/dev/xvda",
              "Ebs" => {
                "DeleteOnTermination" => true,
                          "Encrypted" => true,
                               "Iops" => 3000,
                         "Throughput" => 125,
                         "VolumeSize" => 100,
                         "VolumeType" => "gp3"
              }
            }
          ]
        }
      },
      "ASGSNSTopic" => {
        "Type" => "AWS::SNS::Topic",
        "Properties" => {
          "Subscription" => [
            {
              "Endpoint" => {"Fn::GetAtt" => ["ASGDrainingFunction", "Arn"]},
              "Protocol" => "lambda"
            }
          ]
        }
      },
      "ASGDrainingFunctionRole" => {
        "Type"=>"AWS::IAM::Role",
        "Properties" => {
          "AssumeRolePolicyDocument" => {
            "Version" => "2012-10-17",
            "Statement" => [
              {
                "Effect"=>"Allow",
                "Principal" => {
                  "Service" => ["lambda.amazonaws.com"]
                },
                "Action" => ["sts:AssumeRole"]
              }
            ]
          },
          "Path" => "/",
          "Policies" => [
            {
              "PolicyName" => "barcelona-#{district.name}-asg-draining-function-role",
              "PolicyDocument" => {
                "Version"=>"2012-10-17",
                "Statement" => [
                  {
                    "Effect"=>"Allow",
                    "Action"=>[
                      "autoscaling:CompleteLifecycleAction",
                      "ecs:ListContainerInstances",
                      "ecs:DescribeContainerInstances",
                      "ecs:UpdateContainerInstancesState",
                      "ecs:ListTasks",
                      "ecs:DescribeTasks",
                      "logs:CreateLogGroup",
                      "logs:CreateLogStream",
                      "logs:PutLogEvents",
                      "sns:Publish"
                    ],
                    "Resource"=>["*"]
                  }
                ]
              }
            }
          ]
        }
      },
      "ASGDrainingFunction" => {
        "Type" => "AWS::Lambda::Function",
        "Properties" => {
          "Code" => {
            "ZipFile" => kind_of(String)
          },
          "Handler" => "index.lambda_handler",
          "Runtime" => "python3.12",
          "Timeout" => "60",
          "Role" => {"Fn::GetAtt" => ["ASGDrainingFunctionRole", "Arn"]},
          "Environment" => {
            "Variables" => {
              "CLUSTER_NAME" => district.name
            }
          }
        },
      },
      "ASGDrainingFunctionPermission" => {
        "Type" => "AWS::Lambda::Permission",
        "Properties" => {
          "FunctionName" => {"Ref" => "ASGDrainingFunction"},
          "Action" => "lambda:InvokeFunction",
          "Principal" => "sns.amazonaws.com",
          "SourceArn" => {"Ref" => "ASGSNSTopic"}
        }
      },
      "LifecycleHookRole" => {
        "Type"=>"AWS::IAM::Role",
        "Properties" => {
          "AssumeRolePolicyDocument" => {
            "Version" => "2012-10-17",
            "Statement" => [
              {
                "Effect"=>"Allow",
                "Principal" => {
                  "Service" => ["autoscaling.amazonaws.com"]
                },
                "Action" => ["sts:AssumeRole"]
              }
            ]
          },
          "ManagedPolicyArns" => [
            "arn:aws:iam::aws:policy/service-role/AutoScalingNotificationAccessRole"
          ]
        }
      },
      "TerminatingLifecycleHook" => {
        "Type" => "AWS::AutoScaling::LifecycleHook",
        "Properties" => {
          "AutoScalingGroupName" => {"Ref" => "ContainerInstanceAutoScalingGroup"},
          "LifecycleTransition" => "autoscaling:EC2_INSTANCE_TERMINATING",
          "NotificationTargetARN" => {"Ref" => "ASGSNSTopic"},
          "RoleARN" => {"Fn::GetAtt" => ["LifecycleHookRole", "Arn"]}
        }
      },
      "InstanceSecurityGroup" => {
        "Type" => "AWS::EC2::SecurityGroup",
        "Properties" => {
          "GroupDescription" => "SG for ECS container instances",
          "VpcId" => {"Ref" => "VPC"},
          "SecurityGroupIngress" => [
            {"IpProtocol" => "tcp",
             "FromPort" => 22,
             "ToPort" => 22,
             "SourceSecurityGroupId" => {"Ref" => "SecurityGroupBastion"}},
            {"IpProtocol" => "icmp",
             "FromPort" => -1,
             "ToPort" => -1,
             "CidrIp" => district.cidr_block},
            {"IpProtocol" => -1,
             "FromPort" => -1,
             "ToPort" => -1,
             "SourceSecurityGroupId" => {"Ref" => "PublicELBSecurityGroup"}},
            {"IpProtocol" => -1,
             "FromPort" => -1,
             "ToPort" => -1,
             "SourceSecurityGroupId" => {"Ref" => "PrivateELBSecurityGroup"}},
            {"IpProtocol" => -1,
             "FromPort" => -1,
             "ToPort" => -1,
             "SourceSecurityGroupId" =>
             {"Ref" => "ContainerInstanceAccessibleSecurityGroup"}}],
          "Tags" => [{"Key" => "barcelona", "Value" => district.name}]
        }
      },
      "InstanceSecurityGroupSelfIngress" => {
        "Type" => "AWS::EC2::SecurityGroupIngress",
        "Properties" => {
          "GroupId" => {"Ref" => "InstanceSecurityGroup"},
          "IpProtocol" => -1,
          "FromPort" => -1,
          "ToPort" => -1,
          "SourceSecurityGroupId" => {"Ref" => "InstanceSecurityGroup"}}},
      "SecurityGroupBastion" => {
        "Type" => "AWS::EC2::SecurityGroup",
        "Properties" => {
          "GroupDescription" => "Security Group for bastion servers",
          "VpcId" => {"Ref" => "VPC"},
          "SecurityGroupIngress" => [
            {"IpProtocol" => "tcp",
             "FromPort" => 22,
             "ToPort" => 22,
             "CidrIp" => "0.0.0.0/0"}],
          "SecurityGroupEgress" => [
            {"IpProtocol" => "tcp",
             "FromPort" => 22,
             "ToPort" => 22,
             "CidrIp" => district.cidr_block},
            {"IpProtocol" => "tcp",
             "FromPort" => 80,
             "ToPort" => 80,
             "CidrIp" => "0.0.0.0/0"},
            {"IpProtocol" => "tcp",
             "FromPort" => 443,
             "ToPort" => 443,
             "CidrIp" => "0.0.0.0/0"},
            {"IpProtocol" => "udp",
             "FromPort" => 1514,
             "ToPort" => 1514,
             "CidrIp" => district.cidr_block},
            {"IpProtocol" => "tcp",
             "FromPort" => 1515,
             "ToPort" => 1515,
             "CidrIp" => district.cidr_block},
          ],
          "Tags" => [{"Key" => "barcelona", "Value" => district.name}]
        }
      },
      "BastionProfile" => {
        "Type" => "AWS::IAM::InstanceProfile",
        "Properties" => {
          "Path" => "/",
          "Roles" => [{"Ref" => "BastionRole"}]
        }
      },
      "BastionRole" => {
        "Type"=>"AWS::IAM::Role",
        "Properties" => {
          "AssumeRolePolicyDocument" => {
            "Version"=>"2012-10-17",
            "Statement" => [
              {
                "Effect"=>"Allow",
                "Principal" => {"Service"=>["ec2.amazonaws.com"]},
                "Action"=>["sts:AssumeRole"]
              }
            ]
          },
          "Path"=>"/",
          "ManagedPolicyArns" => [
            "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM",
            "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
          ],
        }
      },
      "BastionLaunchConfiguration" => {
        "Type" => "AWS::AutoScaling::LaunchConfiguration",
        "Properties" => {
          "InstanceType" => "t3.small",
          "MetadataOptions"=>{"HttpTokens"=>"required"},
          "IamInstanceProfile" => {"Ref" => "BastionProfile"},
          "ImageId" => kind_of(String),
          "UserData" => anything,
          "AssociatePublicIpAddress" => true,
          "SecurityGroups" => [
            {"Ref" => "SecurityGroupBastion"}
          ],
          "BlockDeviceMappings" => [
            {
              "DeviceName" =>"/dev/xvda", 
              "Ebs" => {
                "DeleteOnTermination" => true,
                "Encrypted" => true,
                "Iops" => 3000,
                "Throughput" => 125,
                "VolumeSize" => 100,
                "VolumeType" => "gp3"
              }
            }
          ],
        }
      },
      "BastionAutoScaling" => {
        "Type" => "AWS::AutoScaling::AutoScalingGroup",
        "DependsOn" => ["VPCGatewayAttachment"],
        "Properties" => {
          "DesiredCapacity" => 1,
          "MaxSize" => 1,
          "MinSize" => 1,
          "HealthCheckType" => "EC2",
          "LaunchConfigurationName" => {"Ref" => "BastionLaunchConfiguration"},
          "VPCZoneIdentifier" => [
            {"Ref" => "SubnetDmz1"},
            {"Ref" => "SubnetDmz2"}
          ],
          "Tags" => [
            {
              "Key" => "Name",
              "Value" => "barcelona-#{district.name}-bastion",
              "PropagateAtLaunch" => true
            },
            {
              "Key" => "barcelona",
              "Value" => district.name,
              "PropagateAtLaunch" => true
            },
            {
              "Key" => "barcelona-role",
              "Value" => "bastion",
              "PropagateAtLaunch" => true
            }
          ]
        },
        "UpdatePolicy" => {
          "AutoScalingReplacingUpdate" => {
            "WillReplace" => true
          }
        }
      },
      "ECSInstanceProfile" => {
        "Type"=>"AWS::IAM::InstanceProfile",
        "Properties" => {
          "Path" => "/",
          "Roles" => [{"Ref"=>"ECSInstanceRole"}]
        }
      },
      "ECSInstanceRole" => {
        "Type"=>"AWS::IAM::Role",
        "Properties" => {
          "AssumeRolePolicyDocument" => {
            "Version"=>"2012-10-17",
            "Statement" => [
              {
                "Effect"=>"Allow",
                "Principal" => {"Service"=>["ec2.amazonaws.com"]},
                "Action"=>["sts:AssumeRole"]
              }
            ]
          },
          "Path"=>"/",
          "ManagedPolicyArns" => [
            "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM",
            "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
            "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
          ],
          "Policies" => [
            {
              "PolicyName" => "barcelona-ecs-container-instance-role",
              "PolicyDocument" => {
                "Version" => "2012-10-17",
                "Statement" => [
                  {
                    "Effect"=>"Allow",
                    "Action" => [
                      "s3:Get*",
                      "s3:List*"
                    ],
                    "Resource"=>["*"]
                  }
                ]
              }
            }
          ]
        }
      },
      "ECSServiceRole" => {
        "Type"=>"AWS::IAM::Role",
        "Properties" => {
          "AssumeRolePolicyDocument" => {
            "Version" => "2012-10-17",
            "Statement" => [
              {
                "Effect"=>"Allow",
                "Principal" => {
                  "Service" => ["ecs.amazonaws.com"]
                },
                "Action" => ["sts:AssumeRole"]
              }
            ]
          },
          "Path" => "/",
          "Policies" => [
            {
              "PolicyName" => "barcelona-ecs-service-role",
              "PolicyDocument" => {
                "Version"=>"2012-10-17",
                "Statement" => [
                  {
                    "Effect"=>"Allow",
                    "Action"=>[
                      "elasticloadbalancing:Describe*",
                      "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
                      "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
                      "ec2:Describe*",
                      "ec2:AuthorizeSecurityGroupIngress"
                    ],
                    "Resource"=>["*"]
                  }
                ]
              }
            }
          ]
        }
      },
      "RouteTableDmz1" => {
        "Type" => "AWS::EC2::RouteTable",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "Tags" => [
            {"Key" => "Name", "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "public"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Public"}]}},
      "RouteDmz1" => {
        "Type" => "AWS::EC2::Route",
        "DependsOn" => ["VPCGatewayAttachment"],
        "Properties" => {
          "RouteTableId" => {"Ref" => "RouteTableDmz1"},
          "DestinationCidrBlock" => "0.0.0.0/0",
          "GatewayId" => {"Ref" => "InternetGateway"}}},
      "NetworkAclDmz1" => {
        "Type" => "AWS::EC2::NetworkAcl",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "Tags" => [
            {"Key" => "Name", "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "public"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Public"}]}},
      "InboundNetworkAclEntryDmz10" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz1"},
          "RuleNumber" => 100,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 22, "To" => 22},
          "Protocol" => 6}},
      "InboundNetworkAclEntryDmz11" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz1"},
          "RuleNumber" => 101,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 80, "To" => 80},
          "Protocol" => 6}},
      "InboundNetworkAclEntryDmz12" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz1"},
          "RuleNumber" => 102,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 443, "To" => 443},
          "Protocol" => 6}},
      "InboundNetworkAclEntryDmz13" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz1"},
          "RuleNumber" => 103,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 1024, "To" => 65535},
          "Protocol" => 6}},
      "InboundNetworkAclEntryDmz14" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz1"},
          "RuleNumber" => 104,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 1024, "To" => 65535},
          "Protocol" => 17}},
      "InboundNetworkAclEntryDmz15" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz1"},
          "RuleNumber" => 105,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 123, "To" => 123},
          "Protocol" => 17}},
      "InboundNetworkAclEntryDmz1ICMP" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz1"},
          "RuleNumber" => 200,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "Icmp" => {"Type" => -1, "Code" => -1},
          "Protocol" => 1}},
      "OutboundNetworkAclEntryDmz1" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz1"},
          "RuleNumber" => 100,
          "Protocol" => -1,
          "RuleAction" => "allow",
          "Egress" => true,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 0, "To" => 65535}}},
      "SubnetDmz1" => {
        "Type" => "AWS::EC2::Subnet",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "CidrBlock" => (IPAddr.new(district.cidr_block) | (129 << 8)).to_s + "/24",
          "AvailabilityZone" =>
          {"Fn::Select" => [0, {"Fn::GetAZs" => {"Ref" => "AWS::Region"}}]},
          "Tags" => [
            {"Key" => "Name",
             "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "Dmz1"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Public"}]}},
      "SubnetRouteTableAssociationDmz1" => {
        "Type" => "AWS::EC2::SubnetRouteTableAssociation",
        "Properties" => {
          "SubnetId" => {"Ref" => "SubnetDmz1"},
          "RouteTableId" => {"Ref" => "RouteTableDmz1"}}},
      "SubnetNetworkAclAssociationDmz1" => {
        "Type" => "AWS::EC2::SubnetNetworkAclAssociation",
        "Properties" => {"SubnetId" => {"Ref" => "SubnetDmz1"},
                         "NetworkAclId" => {"Ref" => "NetworkAclDmz1"}}},
      "RouteTableDmz2" => {
        "Type" => "AWS::EC2::RouteTable",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "Tags" => [
            {"Key" => "Name", "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "public"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Public"}]}},
      "RouteDmz2" => {
        "Type" => "AWS::EC2::Route",
        "DependsOn" => ["VPCGatewayAttachment"],
        "Properties" => {
          "RouteTableId" => {"Ref" => "RouteTableDmz2"},
          "DestinationCidrBlock" => "0.0.0.0/0",
          "GatewayId" => {"Ref" => "InternetGateway"}}},
      "NetworkAclDmz2" => {
        "Type" => "AWS::EC2::NetworkAcl",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "Tags" => [
            {"Key" => "Name", "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "public"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Public"}]}},
      "InboundNetworkAclEntryDmz20" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz2"},
          "RuleNumber" => 100,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 22, "To" => 22},
          "Protocol" => 6}},
      "InboundNetworkAclEntryDmz21" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz2"},
          "RuleNumber" => 101,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 80, "To" => 80},
          "Protocol" => 6}},
      "InboundNetworkAclEntryDmz22" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz2"},
          "RuleNumber" => 102,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 443, "To" => 443},
          "Protocol" => 6}},
      "InboundNetworkAclEntryDmz23" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz2"},
          "RuleNumber" => 103,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 1024, "To" => 65535},
          "Protocol" => 6}},
      "InboundNetworkAclEntryDmz24" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz2"},
          "RuleNumber" => 104,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 1024, "To" => 65535},
          "Protocol" => 17}},
      "InboundNetworkAclEntryDmz25" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz2"},
          "RuleNumber" => 105,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 123, "To" => 123},
          "Protocol" => 17}},
      "InboundNetworkAclEntryDmz2ICMP" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz2"},
          "RuleNumber" => 200,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "Icmp" => {"Type" => -1, "Code" => -1},
          "Protocol" => 1}},
      "OutboundNetworkAclEntryDmz2" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclDmz2"},
          "RuleNumber" => 100,
          "Protocol" => -1,
          "RuleAction" => "allow",
          "Egress" => true,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 0, "To" => 65535}}},
      "SubnetDmz2" => {
        "Type" => "AWS::EC2::Subnet",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "CidrBlock" => (IPAddr.new(district.cidr_block) | (130 << 8)).to_s + "/24",
          "AvailabilityZone" => {"Fn::Select" => [1, {"Fn::GetAZs" => {"Ref" => "AWS::Region"}}]},
          "Tags" => [
            {"Key" => "Name", "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "Dmz2"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Public"}]}},
      "SubnetRouteTableAssociationDmz2" => {
        "Type" => "AWS::EC2::SubnetRouteTableAssociation",
        "Properties" => {
          "SubnetId" => {"Ref" => "SubnetDmz2"},
          "RouteTableId" => {"Ref" => "RouteTableDmz2"}}},
      "SubnetNetworkAclAssociationDmz2" => {
        "Type" => "AWS::EC2::SubnetNetworkAclAssociation",
        "Properties" => {
          "SubnetId" => {"Ref" => "SubnetDmz2"},
          "NetworkAclId" => {"Ref" => "NetworkAclDmz2"}}},
      "RouteTableTrusted1" => {
        "Type" => "AWS::EC2::RouteTable",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "Tags" => [
            {"Key" => "Name", "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "private"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Private"}]}},
      "NetworkAclTrusted1" => {
        "Type" => "AWS::EC2::NetworkAcl",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "Tags" => [
            {"Key" => "Name", "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "private"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Private"}]}},
      "InboundNetworkAclEntryTrusted10" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted1"},
          "RuleNumber" => 100,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "10.0.0.0/8",
          "PortRange" => {"From" => 22, "To" => 22},
          "Protocol" => 6}},
      "InboundNetworkAclEntryTrusted11" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted1"},
          "RuleNumber" => 101,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 80, "To" => 80},
          "Protocol" => 6}},
      "InboundNetworkAclEntryTrusted12" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted1"},
          "RuleNumber" => 102,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 443, "To" => 443},
          "Protocol" => 6}},
      "InboundNetworkAclEntryTrusted13" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted1"},
          "RuleNumber" => 103,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 1024, "To" => 65535},
          "Protocol" => 6}},
      "InboundNetworkAclEntryTrusted14" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted1"},
          "RuleNumber" => 104,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 1024, "To" => 65535},
          "Protocol" => 17}},
      "InboundNetworkAclEntryTrusted15" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted1"},
          "RuleNumber" => 105,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 123, "To" => 123},
          "Protocol" => 17}},
      "InboundNetworkAclEntryTrusted1ICMP" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted1"},
          "RuleNumber" => 200,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "Icmp" => {"Type" => -1, "Code" => -1},
          "Protocol" => 1}},
      "OutboundNetworkAclEntryTrusted1" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted1"},
          "RuleNumber" => 100,
          "Protocol" => -1,
          "RuleAction" => "allow",
          "Egress" => true,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 0, "To" => 65535}}},
      "SubnetTrusted1" => {
        "Type" => "AWS::EC2::Subnet",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "CidrBlock" => (IPAddr.new(district.cidr_block) | (1 << 8)).to_s + "/24",
          "AvailabilityZone" => {"Fn::Select" => [0, {"Fn::GetAZs" => {"Ref" => "AWS::Region"}}]},
          "Tags" => [
            {"Key" => "Name", "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "Trusted1"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Private"}]}},
      "SubnetRouteTableAssociationTrusted1" => {
        "Type" => "AWS::EC2::SubnetRouteTableAssociation",
        "Properties" => {
          "SubnetId" => {"Ref" => "SubnetTrusted1"},
          "RouteTableId" => {"Ref" => "RouteTableTrusted1"}}},
      "SubnetNetworkAclAssociationTrusted1" => {
        "Type" => "AWS::EC2::SubnetNetworkAclAssociation",
        "Properties" => {
          "SubnetId" => {"Ref" => "SubnetTrusted1"},
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted1"}}},
      "RouteTableTrusted2" => {
        "Type" => "AWS::EC2::RouteTable",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "Tags" => [
            {"Key" => "Name", "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "private"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Private"}]}},
      "NetworkAclTrusted2" => {
        "Type" => "AWS::EC2::NetworkAcl",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "Tags" => [
            {"Key" => "Name", "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "private"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Private"}]}},
      "InboundNetworkAclEntryTrusted20" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted2"},
          "RuleNumber" => 100,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "10.0.0.0/8",
          "PortRange" => {"From" => 22, "To" => 22},
          "Protocol" => 6}},
      "InboundNetworkAclEntryTrusted21" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted2"},
          "RuleNumber" => 101,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 80, "To" => 80},
          "Protocol" => 6}},
      "InboundNetworkAclEntryTrusted22" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted2"},
          "RuleNumber" => 102,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 443, "To" => 443},
          "Protocol" => 6}},
      "InboundNetworkAclEntryTrusted23" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted2"},
          "RuleNumber" => 103,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 1024, "To" => 65535},
          "Protocol" => 6}},
      "InboundNetworkAclEntryTrusted24" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted2"},
          "RuleNumber" => 104,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 1024, "To" => 65535},
          "Protocol" => 17}},
      "InboundNetworkAclEntryTrusted25" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted2"},
          "RuleNumber" => 105,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 123, "To" => 123},
          "Protocol" => 17}},
      "InboundNetworkAclEntryTrusted2ICMP" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted2"},
          "RuleNumber" => 200,
          "RuleAction" => "allow",
          "Egress" => false,
          "CidrBlock" => "0.0.0.0/0",
          "Icmp" => {"Type" => -1, "Code" => -1},
          "Protocol" => 1}},
      "OutboundNetworkAclEntryTrusted2" => {
        "Type" => "AWS::EC2::NetworkAclEntry",
        "Properties" => {
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted2"},
          "RuleNumber" => 100,
          "Protocol" => -1,
          "RuleAction" => "allow",
          "Egress" => true,
          "CidrBlock" => "0.0.0.0/0",
          "PortRange" => {"From" => 0, "To" => 65535}}},
      "SubnetTrusted2" => {
        "Type" => "AWS::EC2::Subnet",
        "Properties" => {
          "VpcId" => {"Ref" => "VPC"},
          "CidrBlock" => (IPAddr.new(district.cidr_block) | (2 << 8)).to_s + "/24",
          "AvailabilityZone" => {
            "Fn::Select" => [1, {"Fn::GetAZs" => {"Ref" => "AWS::Region"}}]},
          "Tags" => [
            {"Key" => "Name", "Value" => {"Fn::Join" => ["-", [{"Ref" => "AWS::StackName"}, "Trusted2"]]}},
            {"Key" => "barcelona", "Value" => district.name},
            {"Key" => "Network", "Value" => "Private"}]}},
      "SubnetRouteTableAssociationTrusted2" => {
        "Type" => "AWS::EC2::SubnetRouteTableAssociation",
        "Properties" => {
          "SubnetId" => {"Ref" => "SubnetTrusted2"},
          "RouteTableId" => {"Ref" => "RouteTableTrusted2"}}},
      "SubnetNetworkAclAssociationTrusted2" => {
        "Type" => "AWS::EC2::SubnetNetworkAclAssociation",
        "Properties" => {
          "SubnetId" => {"Ref" => "SubnetTrusted2"},
          "NetworkAclId" => {"Ref" => "NetworkAclTrusted2"}}},
      "NotificationTopic" => {
        "Type" => "AWS::SNS::Topic",
        "Properties" => {
          "DisplayName" => "district-#{district.name}-notification"
        }
      },
      "BucketPolicy" => {
        "Type" => "AWS::S3::BucketPolicy",
        "Properties" => {
          "Bucket" => district.s3_bucket_name,
          "PolicyDocument" => {
            "Statement" => [
              {
                "Action" => ["s3:PutObject"],
                "Effect" => "Allow",
                "Resource" => {
                  "Fn::Join" => ["",
                                 ["arn:aws:s3:::",
                                  "#{district.s3_bucket_name}/elb_logs/*/AWSLogs/",
                                  {"Ref" => "AWS::AccountId"},
                                  "/*"
                                 ]
                                ],
                },
                "Principal" => {"AWS" => Barcelona::Network::ELB_ACCOUNT_IDS[district.region]}
              }
            ]
          }
        }
      }
    }
    expect(generated["Resources"]).to match expected
  end

  context "when nat_type is instance" do
    it "includes NAT resources" do
      district.nat_type = "instance"
      stack = described_class.new(district)
      generated = JSON.load(stack.target!)
      expect(generated["Resources"]["NATInstance1"]).to be_present
      expect(generated["Resources"]["SecurityGroupNAT"]).to be_present
      expect(generated["Resources"]["RouteNATForRouteTableTrusted1"]).to be_present
    end
  end

  context "when nat_type is managed_gateway" do
    it "includes NAT resources" do
      district.nat_type = "managed_gateway"
      stack = described_class.new(district)
      generated = JSON.load(stack.target!)
      expect(generated["Resources"]["EIPForNATManagedGateway1"]).to be_present
      expect(generated["Resources"]["EIPForNATManagedGateway1"]["DeletionPolicy"]).to eq "Retain"
      expect(generated["Resources"]["NATManagedGateway1"]).to be_present
      expect(generated["Resources"]["RouteNATForRouteTableTrusted1"]).to be_present
    end
  end

  context "when nat_type is managed_gateway_multi_az" do
    it "includes NAT resources" do
      district.nat_type = "managed_gateway_multi_az"
      stack = described_class.new(district)
      generated = JSON.load(stack.target!)
      expect(generated["Resources"]["EIPForNATManagedGateway1"]).to be_present
      expect(generated["Resources"]["EIPForNATManagedGateway1"]["DeletionPolicy"]).to eq "Retain"
      expect(generated["Resources"]["NATManagedGateway1"]).to be_present
      expect(generated["Resources"]["RouteNATForRouteTableTrusted1"]).to be_present
      expect(generated["Resources"]["EIPForNATManagedGateway2"]).to be_present
      expect(generated["Resources"]["EIPForNATManagedGateway2"]["DeletionPolicy"]).to eq "Retain"
      expect(generated["Resources"]["NATManagedGateway2"]).to be_present
      expect(generated["Resources"]["RouteNATForRouteTableTrusted2"]).to be_present
    end
  end

  it "m6i.large instance type is ebs optimized" do
    district.nat_type = nil
    district.cluster_instance_type = "m6i.large"
    stack = described_class.new(district)
    generated = JSON.load(stack.target!)
    expect(generated["Resources"]["ContainerInstanceLaunchConfiguration"]["Properties"]["EbsOptimized"]).to eq true
  end

  it "m1.large instance type is not ebs optimized by default" do
    district.nat_type = nil
    district.cluster_instance_type = "m1.large"
    stack = described_class.new(district)
    generated = JSON.load(stack.target!)
    expect(generated["Resources"]["ContainerInstanceLaunchConfiguration"]["Properties"]["EbsOptimized"]).to eq false
  end

end

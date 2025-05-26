module Barcelona
  module Network
    class BastionBuilder < CloudFormation::Builder
      # https://aws.amazon.com/amazon-linux-2/release-notes/
      # Amazon Linux 2 AMI
      # You can see the latest version stored in public SSM parameter store
      # https://ap-northeast-1.console.aws.amazon.com/systems-manager/parameters/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2/description?region=ap-northeast-1
      # latest info is Version: 150, LastModifiedDate: 2025-05-15T05:18:06.297000+09:00
      AMI_IDS = {
        "us-east-1"      => "ami-09f4814ae750baed6",
        "us-east-2"      => "ami-0d4596c0733abc100",
        "us-west-1"      => "ami-05cb9251eea88c2ef",
        "us-west-2"      => "ami-061211670aadd4f55",
        "eu-west-1"      => "ami-0a4ca8562c4de78ff",
        "eu-west-2"      => "ami-05ec93917eaf07118",
        "eu-west-3"      => "ami-0746ed6b6c0683e67",
        "eu-central-1"      => "ami-0e8726850f0cb6d73",
        "ap-northeast-1"      => "ami-0227b347afc3e5a45",
        "ap-northeast-2"      => "ami-0bb60994bcb22cc2c",
        "ap-southeast-1"      => "ami-02f7b163d79aae0cb",
        "ap-southeast-2"      => "ami-0fdece716edb9ff41",
        "ca-central-1"      => "ami-009db0e577f46d951",
        "ap-south-1"      => "ami-06e753fac3cb1f27f",
        "sa-east-1"      => "ami-09e1669b87910270d",
      }

      def build_resources
        add_resource("AWS::EC2::SecurityGroup", "SecurityGroupBastion") do |j|
          j.GroupDescription "Security Group for bastion servers"
          j.VpcId ref("VPC")
          j.SecurityGroupIngress [
            {
              "IpProtocol" => "tcp",
              "FromPort" => 22,
              "ToPort" => 22,
              "CidrIp" => "0.0.0.0/0"
            }
          ]
          j.SecurityGroupEgress [
            {
              "IpProtocol" => "tcp",
              "FromPort" => 22,
              "ToPort" => 22,
              "CidrIp" => options[:cidr_block]
            },
            {
              "IpProtocol" => "tcp",
              "FromPort" => 80,
              "ToPort" => 80,
              "CidrIp" => '0.0.0.0/0'
            },
            {
              "IpProtocol" => "tcp",
              "FromPort" => 443,
              "ToPort" => 443,
              "CidrIp" => '0.0.0.0/0'
            },
            # OSSEC agent
            {
              "IpProtocol" => "udp",
              "FromPort" => 1514,
              "ToPort" => 1514,
              "CidrIp" => options[:cidr_block]
            },
            # OSSEC authd
            {
              "IpProtocol" => "tcp",
              "FromPort" => 1515,
              "ToPort" => 1515,
              "CidrIp" => options[:cidr_block]
            },
          ]
          j.Tags [
            tag("barcelona", stack.district.name)
          ]
        end

        add_resource("AWS::IAM::InstanceProfile", "BastionProfile") do |j|
          j.Path "/"
          j.Roles [ref("BastionRole")]
        end

        add_resource("AWS::IAM::Role", "BastionRole") do |j|
          j.AssumeRolePolicyDocument do |j|
            j.Version "2012-10-17"
            j.Statement [
              {
                "Effect" => "Allow",
                "Principal" => {
                  "Service" => ["ec2.amazonaws.com"]
                },
                "Action" => ["sts:AssumeRole"]
              }
            ]
          end
          j.Path "/"
          j.ManagedPolicyArns ["arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM", "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"]
        end

        add_resource("AWS::AutoScaling::LaunchConfiguration", "BastionLaunchConfiguration") do |j|
          j.IamInstanceProfile ref("BastionProfile")
          j.ImageId AMI_IDS[district.region]
          j.InstanceType "t3.small"
          j.SecurityGroups [ref("SecurityGroupBastion")]
          j.AssociatePublicIpAddress true
          j.UserData user_data
          j.MetadataOptions do |m|
            m.HttpTokens 'required'
          end
          j.BlockDeviceMappings [
            # Root volume
            # https://docs.aws.amazon.com/AmazonECS/latest/developerguide/al2ami-storage-config.html
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
        end

        add_resource(BastionAutoScaling, "BastionAutoScaling",
                     district_name: district.name,
                     depends_on: ["VPCGatewayAttachment"])
      end

      def user_data
        ud = InstanceUserData.new
        ud.packages += ["aws-cli", "awslogs", "yum-cron"]
        ud.add_user("hopper")
        ud.add_file("/etc/ssh/ssh_ca_key.pub", "root:root", "644", district.ssh_format_ca_public_key)

        log_group_name = "Barcelona/#{district.name}/bastion"
        ud.add_file("/etc/awslogs/awslogs.conf", "root:root", "644", <<~EOS)
          [general]
          state_file = /var/lib/awslogs/agent-state

          [/var/log/dmesg]
          file = /var/log/dmesg
          log_group_name = #{log_group_name}
          log_stream_name = {ec2_id}/var/log/dmesg

          [/var/log/messages]
          file = /var/log/messages
          log_group_name = #{log_group_name}
          log_stream_name = {ec2_id}/var/log/messages
          datetime_format = %b %d %H:%M:%S

          [/var/log/secure]
          file = /var/log/secure
          log_group_name = #{log_group_name}
          log_stream_name = {ec2_id}/var/log/secure
          datetime_format = %b %d %H:%M:%S
        EOS

        ud.run_commands += [
          # imdsv2
          'IMDSTOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 3600"`',

          # awslogs
          'ec2_id=$(curl -H "X-aws-ec2-metadata-token: $IMDSTOKEN" -v http://169.254.169.254/latest/meta-data/instance-id)',
          # There are cases when we must wait for meta-data
          'while [ "$ec2_id" = "" ]; do sleep 1 ; ec2_id=$(curl -H "X-aws-ec2-metadata-token: $IMDSTOKEN" -v http://169.254.169.254/latest/meta-data/instance-id) ; done',
          'sed -i -e "s/{ec2_id}/$ec2_id/g" /etc/awslogs/awslogs.conf',
          'sed -i -e "s/us-east-1/'+district.region+'/g" /etc/awslogs/awscli.conf',
          "systemctl start awslogsd",

          "service yum-cron start",
          'printf "\nTrustedUserCAKeys /etc/ssh/ssh_ca_key.pub\n" >> /etc/ssh/sshd_config',
          'sed -i -e "s/^PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config',
          "service sshd restart",

          # Install AWS Inspector agent
          "curl https://d1wk0tztpsntt1.cloudfront.net/linux/latest/install | bash"
        ]
        ud.build
      end

      def district
        stack.district
      end
    end
  end
end

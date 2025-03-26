module Backend::Ecs::V2
  class ServiceStack < CloudFormation::Stack
    class Builder < CloudFormation::Builder
      def build_resources
        deps = []
        if use_alb?
          deps = []
          if !service&.heritage&.review?
            deps << 'LBListenerRuleHTTP'
          end

          if listener&.endpoint&.https_listener_id&.present?
            deps << 'LBListenerRuleHTTPS'
          end
        end

        add_resource("AWS::ECS::Service", "ECSService", { depends_on: deps }) do |j|          j.Cluster district.name
          j.TaskDefinition options[:task_definition]
          j.DesiredCount options[:desired_count]
          if use_tcp_load_balancer?
            port_mapping = service.port_mappings.lb_registerable.first
            container_name = service.service_name
            container_port = port_mapping.container_port
            if port_mapping.http? || port_mapping.https?
              container_name = "#{service.service_name}-revpro"
              container_port = port_mapping.lb_port
            end

            j.Role ref("ECSServiceRole")
            j.LoadBalancers [
              {
                "LoadBalancerName" => ref("ClassicLoadBalancer"),
                "ContainerPort" => container_port,
                "ContainerName" => container_name
              }
            ]
          elsif use_alb?
            j.Role ref("ECSServiceRole")
            j.LoadBalancers [
              {
                "TargetGroupArn" => ref("LBTargetGroup1"),
                "ContainerPort" => 80,
                "ContainerName" => "#{service.service_name}-revpro"
              }
            ]
          end
        end

        if use_tcp_load_balancer?
          build_service_role
          build_classic_elb
        elsif use_alb?
          build_service_role
          build_alb_listener
        end
      end

      def build_service_role
        add_resource("AWS::IAM::Role", "ECSServiceRole") do |j|
          j.AssumeRolePolicyDocument do |j|
            j.Version "2012-10-17"
            j.Statement [
              {
                "Effect" => "Allow",
                "Principal" => {
                  "Service" => ["ecs.amazonaws.com"]
                },
                "Action" => ["sts:AssumeRole"]
              }
            ]
          end
          j.Path "/"
          j.Policies [
            {
              "PolicyName" => "barcelona-ecs-service-role",
              "PolicyDocument" => {
                "Version" => "2012-10-17",
                "Statement" => [
                  {
                    "Effect" => "Allow",
                    "Action" => [
                      "ec2:AttachNetworkInterface",
                      "ec2:CreateNetworkInterface",
                      "ec2:CreateNetworkInterfacePermission",
                      "ec2:DeleteNetworkInterface",
                      "ec2:DeleteNetworkInterfacePermission",
                      "ec2:Describe*",
                      "ec2:DetachNetworkInterface",
                      "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
                      "elasticloadbalancing:DeregisterTargets",
                      "elasticloadbalancing:Describe*",
                      "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
                      "elasticloadbalancing:RegisterTargets",
                      "route53:ChangeResourceRecordSets",
                      "route53:CreateHealthCheck",
                      "route53:DeleteHealthCheck",
                      "route53:Get*",
                      "route53:List*",
                      "route53:UpdateHealthCheck",
                      "servicediscovery:DeregisterInstance",
                      "servicediscovery:Get*",
                      "servicediscovery:List*",
                      "servicediscovery:RegisterInstance",
                      "servicediscovery:UpdateInstanceCustomHealthStatus"
                    ],
                    "Resource" => ["*"]
                  }
                ]
              }
            }
          ]
        end
      end

      def build_classic_elb
        add_resource("AWS::ElasticLoadBalancing::LoadBalancer", "ClassicLoadBalancer") do |j|
          scheme = service.public? ? "internet-facing" : "internal"
          subnets = district.subnets(service.public? ? "Public" : "Private")
          security_group = service.public? ? district.public_elb_security_group : district.private_elb_security_group
          j.LoadBalancerName "lb-#{service.service_name}"
          j.Subnets subnets.map(&:subnet_id)
          j.Scheme scheme
          j.SecurityGroups [security_group]
          j.CrossZone true
          j.HealthCheck do |j|
            j.Target "TCP:#{service.port_mappings.first.host_port}"
            j.Interval 5
            j.Timeout 4
            j.UnhealthyThreshold 2
            j.HealthyThreshold 2
          end
          j.Tags [
            tag("barcelona", district.name),
            tag("barcelona-heritage", service.heritage.name)
          ]
          j.Listeners(service.port_mappings.lb_registerable.map do |pm|
            {
              "Protocol" => "TCP",
              "LoadBalancerPort" => pm.lb_port,
              "InstanceProtocol" => "TCP",
              "InstancePort" => pm.host_port
            }
          end)
          j.ConnectionDrainingPolicy do |j|
            j.Enabled true
            j.Timeout 60
          end

          j.AccessLoggingPolicy do |j|
            j.Enabled true
            j.EmitInterval 5 # In minutes
            j.S3BucketName district.s3_bucket_name
            j.S3BucketPrefix "elb_logs/heritage/#{service.name}"
          end

          # Enable ProxyProtocol for http/https host ports
          ports = service.port_mappings.where(protocol: %w[http https]).pluck(:host_port)
          ports += service.port_mappings.where(enable_proxy_protocol: true).pluck(:host_port)
          if ports.present?
            policy = {
              "PolicyType" => "ProxyProtocolPolicyType",
              "PolicyName" => "#{service.service_name}--ProxyProtocol",
              "InstancePorts" => ports,
              "Attributes" => [
                {"Name" => "ProxyProtocol", "Value" => true}
              ]
            }
            j.Policies [policy]
          end
        end

        add_resource("AWS::Route53::RecordSet", "RecordSet") do |j|
          hosted_zone = district.aws.route53.get_hosted_zone(id: district.private_hosted_zone_id).hosted_zone
          j.HostedZoneId district.private_hosted_zone_id
          j.Name [service.name,
                  service.heritage.name,
                  service.district.name,
                  hosted_zone.name].join(".")
          j.TTL 300
          j.Type "CNAME"
          j.ResourceRecords [get_attr("ClassicLoadBalancer", "DNSName")]
        end
      end

      def build_alb_listener
        if !service&.heritage&.review?
          add_resource("AWS::ElasticLoadBalancingV2::ListenerRule", "LBListenerRuleHTTP") do |j|
            j.Actions [{"TargetGroupArn" => ref("LBTargetGroup1"), "Type" => "forward"}]
            j.Conditions(listener.rule_conditions.map { |c| {"Field" => c["type"], "Values" => [c["value"]]} })
            j.ListenerArn listener.endpoint.http_listener_id
            j.Priority listener.rule_priority
          end
        end

        if listener.endpoint.https_listener_id.present?
          add_resource("AWS::ElasticLoadBalancingV2::ListenerRule", "LBListenerRuleHTTPS") do |j|
            j.Actions [{"TargetGroupArn" => ref("LBTargetGroup1"), "Type" => "forward"}]
            j.Conditions(listener.rule_conditions.map { |c| {"Field" => c["type"], "Values" => [c["value"]]} })
            j.ListenerArn listener.endpoint.https_listener_id
            j.Priority listener.rule_priority
          end
        end

        add_resource("AWS::ElasticLoadBalancingV2::TargetGroup", "LBTargetGroup1") do |j|
          j.VpcId district.vpc_id
          j.HealthCheckIntervalSeconds listener.health_check_interval
          j.HealthCheckPath listener.health_check_path
          j.HealthyThresholdCount 2
          j.Matcher do |j|
            j.HttpCode "200-299"
          end
          j.Port 80
          j.Protocol "HTTP"
          j.TargetGroupAttributes [
            {"Key" => "deregistration_delay.timeout_seconds", "Value" => "60"}
          ]
          j.Tags [
            tag("barcelona", district.name)
          ]
        end
      end

      def service
        options[:service]
      end

      def district
        service.district
      end

      def listener
        # For now we don't support multiple listeners
        service.listeners.first
      end

      def use_tcp_load_balancer?
        # Using port_mappings or hosts requires ELB run in TCP mode which is supported
        # only by Classic ELB. Only in the case above we use Classic ELB
        !use_alb? && (service.port_mappings.present? || service.hosts.present?)
      end

      def use_alb?
        listener.present?
      end
    end

    attr_accessor :task_definition, :desired_count

    def initialize(service)
      stack_name = "#{service.district.name}-#{service.service_name}"
      @service = service
      super(stack_name)
    end

    def build
      super do |builder|
        builder.add_builder Builder.new(self, {
          service: @service,
          task_definition: task_definition,
          desired_count: desired_count
        })
      end
    end
  end
end

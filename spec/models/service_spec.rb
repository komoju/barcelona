require 'rails_helper'

describe Service do
  let(:heritage) { create :heritage }
  let(:service) { create :web_service, heritage: heritage }

  it { expect{service.save}.to_not raise_error }

  describe '#save_and_update_container_count!' do
    it 'saves and sets the container count' do
      expect(service.desired_container_count).to eq nil

      district = double('District')
      allow(service).to receive(:district) { district }
      allow(district).to receive(:name) { 'districtest' }

      ecs = double('ECS')
      allow(service).to receive(:ecs) { ecs }
      allow(service).to receive(:logical_name) { 'abc' }

      expect(ecs).to receive(:update_service).with({
        desired_count: 10,
        cluster: 'districtest',
        service: 'abc'
      })

      service.save_and_update_container_count!(10)

      expect(service.desired_container_count).to eq 10
    end
  end

  describe '#logical_name' do
    it 'gives the name of the service' do
      allow(service).to receive(:arn) { 'arn:aws:ecs:un-north-2:1234567890:service/testdistrict/testdistrict-testserv-abcdef' }

      expect(service.logical_name).to eq 'testdistrict-testserv-abcdef'
    end

    it 'throws an error is arn is nil' do
      allow(service).to receive(:arn) { nil }

      expect{service.logical_name}.to raise_error Service::ServiceNotFoundException
    end
  end

  describe '#arn' do
    it 'searches the array and finds the ARN' do
      allow(service).to receive(:service_arns) { ['arn:hello', 'ggg:hello'] }
      allow(service).to receive(:arn_prefix) { 'arn:' }

      expect(service.arn).to eq 'arn:hello'
    end

    it 'searches the array and finds a legacy ARN' do
      allow(service).to receive(:service_arns) { ['arn:old:schwarzenegger', 'ggg:hello'] }
      allow(service).to receive(:arn_prefix) { 'arn:new' }
      allow(service).to receive(:arn_prefix_legacy) { 'arn:old' }

      expect(service.arn).to eq 'arn:old:schwarzenegger'
    end

    it 'returns nil if no ARN' do
      allow(service).to receive(:service_arns) { ['kkk:hello', 'ggg:hello'] }
      allow(service).to receive(:arn_prefix) { 'arn:' }

      expect(service.arn).to be_nil
    end
  end

  describe '#service_arns' do
    it 'returns service arns' do
      district = double('District', name: 'testdistrict')

      # The paginated results coming back from AWS comes in the
      # form of an object that contains a 'next token' that can
      # be used to find the next page of results.

      # As a result just grabbing 'service_arns' is not enough as
      # the number of results returned depends on what is hardcoded
      # as default in the library, and this only the first page
      # of results.

      # AWS (sdk~>3) recently allows us to use 'each' to iterate,
      # saving us the pain of looping back the next token. Hence:

      # We mock the object this way not because this is how it works
      # but because it is useful to think about the returned object
      # in this way, and this is the only aspect about its behavior
      # that we care about.
      result = [
        double('PaginatedObject', service_arns: ['abc']),
        double('PaginatedObject', service_arns: ['def'])
      ];

      ecs = double('ECS')
      allow(ecs).to receive(:list_services).with(cluster: 'testdistrict') { result }

      allow(service).to receive(:district) { district }
      allow(service).to receive(:ecs) { ecs }

      expect(service.service_arns).to eq ['abc', 'def']
    end
  end

  describe '#arn_prefix' do
    it 'produces a prefix for the arn' do
      district = double('District',
        region: 'un-north-2',
        name: 'testdistrict',
        aws: double('AWS',
          sts: double('STS', get_caller_identity: {
            account: '1234567890'
          })
        )
      )
      allow(service).to receive(:district) { district }
      allow(service).to receive(:service_name) { 'testserv' }

      expect(service.arn_prefix).to eq 'arn:aws:ecs:un-north-2:1234567890:service/testdistrict/testdistrict-testserv-ECSService'
    end
  end

  describe '#arn_prefix_legacy' do
    it 'produces a prefix for the arn that conforms to the legacy version' do
      district = double('District',
        region: 'un-north-2',
        name: 'old',
        aws: double('AWS',
          sts: double('STS', get_caller_identity: {
            account: '11111111'
          })
        )
      )
      allow(service).to receive(:district) { district }
      allow(service).to receive(:service_name) { 'serv' }

      expect(service.arn_prefix_legacy).to eq 'arn:aws:ecs:un-north-2:11111111:service/old-serv-ECSService'
    end
  end

  describe 'handling port mappings' do
    context 'created with default port' do
      before { service.save }
      it 'should create http and https port mappings' do
        expect(service.port_mappings).to have(2).items
        http_mapping = service.port_mappings.find_by_lb_port(80)
        expect(http_mapping.container_port).to eq(Service::WEB_CONTAINER_PORT_DEFAULT)
        https_mapping = service.port_mappings.find_by_lb_port(443)
        expect(https_mapping.container_port).to eq(Service::WEB_CONTAINER_PORT_DEFAULT)
      end
    end

    context 'created with specified port' do
      before { service.save }
      let(:service) { create :web_service, heritage: heritage, web_container_port: 6000 }
      it 'should create http and https port mappings with the specifed port' do
        expect(service.port_mappings).to have(2).items
        http_mapping = service.port_mappings.find_by_lb_port(80)
        expect(http_mapping.container_port).to eq(6000)
        https_mapping = service.port_mappings.find_by_lb_port(443)
        expect(https_mapping.container_port).to eq(6000)
      end
    end

    context 'update specified port' do
      before do
        service.save
        service.web_container_port = 6000
        service.save
      end

      it 'should create http and https port mappings with the specifed port' do
        expect(service.port_mappings).to have(2).items
        http_mapping = service.port_mappings.find_by_lb_port(80)
        expect(http_mapping.container_port).to eq(6000)
        https_mapping = service.port_mappings.find_by_lb_port(443)
        expect(https_mapping.container_port).to eq(6000)
      end
    end

    context 'created with specified port and extra mapping' do
      before { service.save }
      let(:udp_mapping) { PortMapping.new(container_port: 3333, protocol: "udp", lb_port: 3333) }
      let(:service) do
        create :web_service, heritage: heritage, web_container_port: 6000, port_mappings: [udp_mapping]
      end
      it 'should create http and https port mappings with the specifed port' do
        expect(service.port_mappings).to have(3).items
        http_mapping = service.port_mappings.find_by_lb_port(80)
        expect(http_mapping.container_port).to eq(6000)
        https_mapping = service.port_mappings.find_by_lb_port(443)
        expect(https_mapping.container_port).to eq(6000)
        udp_mapping = service.port_mappings.find_by_lb_port(3333)
        expect(udp_mapping.container_port).to eq(3333)
      end
    end
  end

  describe '#service_deployments' do
    it 'finds the service deployments for the current district' do
      s1 = create :service
      s1d1 = create :service_deployment, service: s1
      s1d2 = create :service_deployment, service: s1

      s2 = create :service
      s2d1 = create :service_deployment, service: s2

      expect(s1.service_deployments).to eq [s1d1, s1d2]
      expect(s2.service_deployments).to eq [s2d1]
    end
  end

  describe '#deployment_finished?' do
    it 'returns true if there are no deployments (backwards compat)' do
      s = create :service

      expect(s).to be_deployment_finished
    end

    it 'returns true if the last one is finished' do
      s = create :service
      create :service_deployment, service: s, completed_at: Time.now

      expect(s).to be_deployment_finished
    end

    it 'returns false if the last one is not yet finished' do
      s = create :service
      create :service_deployment, service: s

      expect(s).to_not be_deployment_finished
    end
  end

  describe '#stack_name' do
    it 'returns the corresponding stack name' do
      s = create :service, name: 'serv'
      allow(s.district).to receive(:name) { 'dist' }
      allow(s.heritage).to receive(:name) { 'heri' }

      expect(s.stack_name).to eq "dist-heri-serv"
    end
  end
end

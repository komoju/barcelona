require 'rails_helper'

describe DeployService, type: :model do
  let(:district) { create :district, name: 'testdistrict' }
  let(:deployer) { DeployService.new(district) }

  describe '.deploy_service' do
    it 'simply creates a service deployment object' do
      heritage = create :heritage, district: district
      service = create :service, heritage: heritage
      DeployService.deploy_service(service)

      expect(ServiceDeployment.last.service).to eq service
    end
  end

  describe '.check_all' do
    it 'iterates through all districts' do
      d1 = create :district
      d2 = create :district
      d3 = create :district

      dsdouble1 = double('DeployService')
      dsdouble2 = double('DeployService')
      dsdouble3 = double('DeployService')

      expect(DeployService).to receive(:new).with(d1) { dsdouble1 }
      expect(DeployService).to receive(:new).with(d2) { dsdouble2 }
      expect(DeployService).to receive(:new).with(d3) { dsdouble3 }

      expect(dsdouble1).to receive(:check)
      expect(dsdouble2).to receive(:check)
      expect(dsdouble3).to receive(:check)

      DeployService.check_all
    end
  end

  describe '#check' do
    it 'is backwards compatible' do
      heritage = create :heritage, name: 'hname', district: district
      service = create :service, name: 'sname', heritage: heritage

      # if no service deployment object was created
      # it would need to create one

      ds = DeployService.new(district)

      expect(ds).to receive(:notify_completed).with(service)
      allow(ds).to receive(:stack_statuses) {
        {
          'testdistrict-hname-sname' => 'UPDATE_COMPLETE'
        }
      }

      ds.check
    end

    it 'updates state of services' do
      heritage = create :heritage, name: 'hname', district: district
      service = create :service, name: 'sname', heritage: heritage
      create :service_deployment, service: service

      ds = DeployService.new(district)

      expect(ds).to receive(:notify_completed).with(service)
      allow(ds).to receive(:stack_statuses) {
        {
          'testdistrict-hname-sname' => 'UPDATE_COMPLETE'
        }
      }

      ds.check
    end

    it 'updates state of services that are not ready yet' do
      heritage = create :heritage, name: 'hname', district: district
      service = create :service, name: 'sname', heritage: heritage
      create :service_deployment, service: service

      ds = DeployService.new(district)

      expect(ds).to receive(:notify_incomplete).with(service)
      allow(ds).to receive(:stack_statuses) {
        {
          'testdistrict-hname-sname' => 'UPDATE_IN_PROGRESS'
        }
      }

      ds.check
    end

    it 'update state of services that are failed' do
      heritage = create :heritage, name: 'hname', district: district
      service = create :service, name: 'sname', heritage: heritage
      create :service_deployment, service: service

      ds = DeployService.new(district)

      expect(ds).to receive(:notify_failed).with(service)
      allow(ds).to receive(:stack_statuses) {
        {
          'testdistrict-hname-sname' => 'UPDATE_ROLLBACK_COMPLETE'
        }
      }

      ds.check
    end
  end

  describe '#stack_statuses' do
    let(:cfclient) { double('CloudformationClient') }

    it 'updates state of services' do
      heritage1 = create :heritage, name: 'heritage1', district: district
      service1 = create :service, name: 'service1', heritage: heritage1

      heritage2 = create :heritage, name: 'heritage2', district: district
      service2 = create :service, name: 'service2', heritage: heritage2

      ds = DeployService.new(district)

      allow(ds).to receive(:cloudformation) { cfclient }

      allow(cfclient).to receive(:list_stacks) do
        [
          double('Response', stack_summaries:[
            double('Summary', {
              stack_name: 'testdistrict-heritage1-service1',
              stack_status: 'UPDATE_COMPLETE'
            }),

            double('Summary', {
              stack_name: 'testdistrict-heritage2-service2',
              stack_status: 'UPDATE_FAILED'
            }),

            double('Summary', {
              stack_name: 'testdistrict-heritage1-service2',
              stack_status: 'UPDATE_IN_PROGRESS'
            })
          ])
        ]
      end

      expect(ds.stack_statuses).to eq({
          'testdistrict-heritage1-service1' => 'UPDATE_COMPLETE',
          'testdistrict-heritage2-service2' => 'UPDATE_FAILED'
      })
    end
  end

  describe '#notify_completed' do
    it 'sets the service deployment to completed' do
      heritage = create :heritage, name: 'sname', district: district
      service = create :service, heritage: heritage
      deployment = create :service_deployment, service: service

      ds = DeployService.new(district)
      ds.notify_completed(service)

      expect(deployment.reload).to be_completed
    end

    it 'sets all deployment objects for that service to completed' do
      heritage = create :heritage, name: 'sname', district: district
      service = create :service, heritage: heritage
      deployment = create :service_deployment, service: service

      # extra deployment objects
      # can happen in race conditions but we should expect it and handle accordingly
      deployment1 = create :service_deployment, service: service
      deployment2 = create :service_deployment, service: service

      ds = DeployService.new(district)
      ds.notify_completed(service)

      expect(deployment.reload).to be_completed
      expect(deployment1.reload).to be_completed
      expect(deployment2.reload).to be_completed
    end

    it 'notifies if the deployment has completed' do
      heritage = create :heritage, name: 'sname', district: district
      service = create :service, name: 'theservice', heritage: heritage
      deployment = create :service_deployment, service: service

      # this is copied from the deploy_runner_job_spec.rb
      event_object = double("Event")
      expect(Event).to receive(:new).with(district) { event_object }
      expect(event_object).to receive(:notify).with(level: :good, message: "[sname] theservice service deployed")

      ds = DeployService.new(district)
      ds.notify_completed(service)
    end
  end

  describe '#notify' do
    it 'logs an error action is nil' do
      district = create :district, name: 'dtest'
      heritage = create :heritage, name: 'htest', district: district
      service = create :service, name: 'stest', heritage: heritage

      logger_double = double('logger')
      expect(Rails).to receive(:logger) { logger_double }
      expect(logger_double).to receive(:error) { "[deploy_service] stack dtest-htest-stest not found!" }

      ds = DeployService.new(district)
      ds.notify(service, nil)
    end
  end

  describe '#notify_incomplete' do
    it 'notifies if the deployment is taking a while' do
      heritage = create :heritage, name: 'sname', district: district
      service = create :service, name: 'naughty', heritage: heritage

      # Let's just agree that 1 hour for deployment is simply simply way too long
      # even if practical circumstances happen to be such that deployments take
      # more than an hour, barcelona deserves to be noisy about it.
      create :service_deployment, service: service, created_at: 1.hour.ago

      event_object = double("Event")
      expect(Event).to receive(:new).with(district) { event_object }
      expect(event_object).to receive(:notify).with(level: :error, message: "[sname] Deploying naughty service has not finished for a while.")

      ds = DeployService.new(district)
      ds.notify_incomplete(service)
    end
  end

  describe '#notify_failed' do
    # This is a new thing
    # the original monitor deployment job did not check for this

    it 'notifies if the deployment has failed' do
      heritage = create :heritage, name: 'sname', district: district
      service = create :service, name: 'bad', heritage: heritage
      deployment = create :service_deployment, service: service

      event_object = double("Event")
      expect(Event).to receive(:new).with(district) { event_object }
      expect(event_object).to receive(:notify).with(level: :error, message: "[sname] Deployment of bad service has failed.")

      ds = DeployService.new(district)
      ds.notify_failed(service)
    end

    it 'sets the service deployment to failed' do
      heritage = create :heritage, name: 'sname', district: district
      service = create :service, name: 'hname', heritage: heritage
      deployment = create :service_deployment, service: service

      ds = DeployService.new(district)
      ds.notify_failed(service)

      expect(deployment.reload).to be_failed
    end

    it 'sets all deployment objects for that service to failed' do
      heritage = create :heritage, name: 'sname', district: district
      service = create :service, name: 'hname', heritage: heritage
      deployment = create :service_deployment, service: service

      # extra deployment objects
      # can happen in race conditions but we should expect it and handle accordingly
      deployment1 = create :service_deployment, service: service
      deployment2 = create :service_deployment, service: service

      ds = DeployService.new(district)
      ds.notify_failed(service)

      expect(deployment.reload).to be_failed
      expect(deployment1.reload).to be_failed
      expect(deployment2.reload).to be_failed
    end
  end
end

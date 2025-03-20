class MonitorDeploymentJob < ActiveJob::Base
  queue_as :default

  def perform(service, count: 0, deployment_id: nil)
    if service.heritage.version == 2
      ServiceDeployment.create!(service: service)
      return
    end

    # old version does not rely on cloudformation and thus has to be
    # polled one by one. We will need to clean this up later.

    if service.deployment_finished?(deployment_id)
      notify(service, message: "#{service.name} service deployed")
    elsif count > 20
      # deploys not finished after 20 minutes are marked as timeout
      notify(service, level: :error, message: "Deploying #{service.name} service has not finished for a while.")
    else
      MonitorDeploymentJob.set(wait: 60.seconds).perform_later(service,
                                                              count: count + 1,
                                                              deployment_id: deployment_id)
    end
  end

  def notify(service, level: :good, message:)
    Rails.logger.info message
    Event.new(service.district).notify(level: level, message: "[#{service.heritage.name}] #{message}")
  end
end

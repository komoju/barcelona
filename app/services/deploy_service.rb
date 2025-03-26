class DeployService

  STATUS_TO_ACTION_MAP = {
                              "CREATE_IN_PROGRESS" => :incomplete,
                                   "CREATE_FAILED" => :failed,
                                 "CREATE_COMPLETE" => :completed,
                            "ROLLBACK_IN_PROGRESS" => :incomplete,
                                 "ROLLBACK_FAILED" => :failed,
                               "ROLLBACK_COMPLETE" => :failed,
                              "DELETE_IN_PROGRESS" => :incomplete,
                                   "DELETE_FAILED" => :failed,
                                 "DELETE_COMPLETE" => :completed,
                              "UPDATE_IN_PROGRESS" => :incomplete,
             "UPDATE_COMPLETE_CLEANUP_IN_PROGRESS" => :incomplete,
                                 "UPDATE_COMPLETE" => :completed,
                                   "UPDATE_FAILED" => :failed,
                     "UPDATE_ROLLBACK_IN_PROGRESS" => :failed,
                          "UPDATE_ROLLBACK_FAILED" => :failed,
    "UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS" => :failed,
                        "UPDATE_ROLLBACK_COMPLETE" => :failed,
                              "REVIEW_IN_PROGRESS" => :incomplete,
                              "IMPORT_IN_PROGRESS" => :incomplete,
                                 "IMPORT_COMPLETE" => :completed,
                     "IMPORT_ROLLBACK_IN_PROGRESS" => :failed,
                          "IMPORT_ROLLBACK_FAILED" => :failed,
                        "IMPORT_ROLLBACK_COMPLETE" => :failed
  }.freeze

  class << self
    def deploy_service(service)
      ServiceDeployment.create!(service: service)
    end

    def check_all
      District.all.each do |district|
        Rails.logger.info("Checking district #{district.name}")
        DeployService.new(district).check
      end
    end
  end

  def initialize(district)
    @district = district
  end

  def check
    @district.heritages.each do |heritage|
      heritage.services.each do |service|
        next if service.deployment.finished?

        status = stack_statuses[service.stack_name]
        action = STATUS_TO_ACTION_MAP[status]
        notify(service, action)
      end
    end
  end

  def notify(service, action)
    if action.nil?
      Rails.logger.error("[deploy_service] stack #{service.stack_name} not found!")
      return
    end

    send("notify_#{action}", service)
  end

  def notify_completed(service)
    Rails.logger.info("Heritage: #{service.heritage.name} Service: #{service.name} Deployment Completed")
    service.service_deployments.unfinished.each do |record|
      record.complete!
    end
    event(service, message: "#{service.name} service deployed")
  end

  def notify_incomplete(service)
    Rails.logger.info("Heritage: #{service.heritage.name} Service: #{service.name} Deployment Incomplete")
    runtime = Time.now - service.deployment.created_at
    if runtime > 20.minutes
      event(service, level: :error, message: "Deploying #{service.name} service has not finished for a while.")
    end
  end

  def notify_failed(service)
    Rails.logger.info("Heritage: #{service.heritage.name} Service: #{service.name} Deployment Failed")
    service.service_deployments.unfinished.each do |record|
      record.fail!
    end
    event(service, level: :error, message: "Deployment of #{service.name} service has failed.")
  end

  def stack_names
    @stack_names ||= begin
      results = {}
      @district.heritages.map do |heritage|
        heritage.services.map do |service|
          results[service.stack_name] = true
        end
      end
      results
    end
  end

  def stack_statuses
    @stack_statuses ||= begin
      results = {}

      cloudformation.list_stacks.each do |response|
        response.stack_summaries.each do |summary|
          if stack_names.key?(summary.stack_name)
            results[summary.stack_name] = summary.stack_status
          end
        end
      end

      Rails.logger.info(results.to_yaml)

      results
    rescue StandardError => e
      Rails.logger.error("Failed to retrieve stack statuses!")
      raise e
    end
  end

  private

  def event(service, level: :good, message:)
    Event.new(@district).notify(level: level, message: "[#{service.heritage.name}] #{message}")
  end

  def cloudformation
    @cloudformation ||= @district.aws.cloudformation
  end

end

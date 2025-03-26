namespace :bcn do
  desc "Check deployments"
  task :deployment_check => :environment do
    Rails.logger = Logger.new(STDOUT)
    Rails.logger.level = :info

    Rails.logger.info("Starting deployment check...")
    DeployService.check_all
  end
end

output "spot_termination_notification" {
  value = var.config.features.enable_spot_termination_notification_watcher ? {
    lambda           = module.termination_notification[0].lambda.function
    lambda_log_group = module.termination_notification[0].lambda.log_group
    lambda_role      = module.termination_notification[0].lambda.role
  } : null
}

output "spot_termination_handler" {
  value = var.config.features.enable_spot_termination_handler ? {
    lambda           = module.termination_handler[0].lambda.function
    lambda_log_group = module.termination_handler[0].lambda.log_group
    lambda_role      = module.termination_handler[0].lambda.role
  } : null
}

output "deregister_retry_queue_url" {
  description = "URL of the SQS queue used for deregistration retries. Null when enable_deregister_retry is false or enable_runner_deregistration is false."
  value       = local.enable_runner_deregistration && var.config.enable_deregister_retry ? aws_sqs_queue.deregister_retry[0].url : null
}

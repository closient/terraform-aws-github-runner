# SQS-based deregistration retry infrastructure (C-243)
#
# When the GitHub API returns 422 ("Runner is currently running a job") during
# deregistration, the termination-watcher Lambdas enqueue a delayed retry message.
# After the delay the instance is gone and the runner appears offline, so the retry
# Lambda can delete the stale registration.
#
# Flow:
#   EC2 terminates → notification/termination Lambda → 422 from GitHub
#     → SendMessage to deregister_retry queue (300 s delay)
#     → deregister-retry Lambda fires → deletes runner from GitHub
#     → If still 422, re-enqueues (up to 3 attempts via DLQ maxReceiveCount)

locals {
  # Canonical name prefix: use var.config.prefix when set, else fall back to empty
  retry_prefix        = var.config.prefix != null ? "${var.config.prefix}-" : ""
  retry_function_name = "${local.retry_prefix}deregister-retry"
}

# ─── SQS: DLQ ─────────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "deregister_retry_dlq" {
  count = local.enable_runner_deregistration && var.config.enable_deregister_retry ? 1 : 0

  name                      = "${local.retry_prefix}deregister-retry-dlq"
  message_retention_seconds = 86400 # 24 hours — enough time to investigate failures

  tags = var.config.tags
}

# ─── SQS: Main retry queue ───────────────────────────────────────────────────

resource "aws_sqs_queue" "deregister_retry" {
  count = local.enable_runner_deregistration && var.config.enable_deregister_retry ? 1 : 0

  name                       = "${local.retry_prefix}deregister-retry"
  delay_seconds              = 300  # 5 min — instance is gone, runner appears offline
  message_retention_seconds  = 3600 # 1 hour — discard if unprocessed
  visibility_timeout_seconds = 60   # Must be >= Lambda timeout (30 s) with headroom

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.deregister_retry_dlq[0].arn
    maxReceiveCount     = 3
  })

  tags = var.config.tags
}

# ─── IAM: retry Lambda role ───────────────────────────────────────────────────

resource "aws_iam_role" "deregister_retry" {
  count = local.enable_runner_deregistration && var.config.enable_deregister_retry ? 1 : 0

  name = "${substr(local.retry_function_name, 0, 54)}-${substr(md5(local.retry_function_name), 0, 8)}"
  path = var.config.role_path != null ? var.config.role_path : "/${var.config.prefix != null ? var.config.prefix : "default"}/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  permissions_boundary = var.config.role_permissions_boundary

  tags = var.config.tags
}

resource "aws_iam_role_policy" "deregister_retry_logs" {
  count = local.enable_runner_deregistration && var.config.enable_deregister_retry ? 1 : 0

  name = "logging-policy"
  role = aws_iam_role.deregister_retry[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = "${aws_cloudwatch_log_group.deregister_retry[0].arn}:*"
    }]
  })
}

resource "aws_iam_role_policy" "deregister_retry_sqs" {
  count = local.enable_runner_deregistration && var.config.enable_deregister_retry ? 1 : 0

  name = "sqs-policy"
  role = aws_iam_role.deregister_retry[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility",
        # Re-enqueue when runner is still busy (will re-delay)
        "sqs:SendMessage",
      ]
      Resource = aws_sqs_queue.deregister_retry[0].arn
    }]
  })
}

resource "aws_iam_role_policy" "deregister_retry_ssm" {
  count = local.enable_runner_deregistration && var.config.enable_deregister_retry ? 1 : 0

  name = "ssm-policy"
  role = aws_iam_role.deregister_retry[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = local.ssm_parameter_arns
    }]
  })
}

# ─── IAM: grant notification + termination Lambdas SendMessage on the queue ──

resource "aws_iam_role_policy" "notification_sqs_retry" {
  count = local.enable_runner_deregistration && var.config.enable_deregister_retry && var.config.features.enable_spot_termination_notification_watcher ? 1 : 0

  name = "sqs-deregister-retry"
  role = module.termination_notification[0].lambda.role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.deregister_retry[0].arn
    }]
  })
}

resource "aws_iam_role_policy" "termination_sqs_retry" {
  count = local.enable_runner_deregistration && var.config.enable_deregister_retry && var.config.features.enable_spot_termination_handler ? 1 : 0

  name = "sqs-deregister-retry"
  role = module.termination_handler[0].lambda.role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.deregister_retry[0].arn
    }]
  })
}

# ─── CloudWatch log group ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "deregister_retry" {
  count = local.enable_runner_deregistration && var.config.enable_deregister_retry ? 1 : 0

  name              = "/aws/lambda/${local.retry_function_name}"
  retention_in_days = var.config.logging_retention_in_days
  kms_key_id        = var.config.logging_kms_key_id
  log_group_class   = var.config.log_class

  tags = var.config.tags
}

# ─── Lambda: deregister-retry ─────────────────────────────────────────────────

resource "aws_lambda_function" "deregister_retry" {
  count = local.enable_runner_deregistration && var.config.enable_deregister_retry ? 1 : 0

  function_name = local.retry_function_name
  role          = aws_iam_role.deregister_retry[0].arn
  handler       = "index.deregisterRetry"
  runtime       = var.config.runtime != null ? var.config.runtime : "nodejs24.x"
  architectures = [var.config.architecture != null ? var.config.architecture : "arm64"]
  timeout       = 30
  memory_size   = var.config.memory_size != null ? var.config.memory_size : 256

  s3_bucket         = var.config.s3_bucket
  s3_key            = var.config.s3_key
  s3_object_version = var.config.s3_object_version
  filename          = var.config.s3_bucket == null ? local.lambda_zip : null
  source_code_hash  = var.config.s3_bucket == null ? filebase64sha256(local.lambda_zip) : null

  environment {
    variables = merge(
      {
        ENVIRONMENT                              = var.config.prefix
        PREFIX                                   = var.config.prefix
        LOG_LEVEL                                = var.config.log_level != null ? var.config.log_level : "info"
        POWERTOOLS_SERVICE_NAME                  = "deregister-retry"
        POWERTOOLS_LOGGER_LOG_EVENT              = "false"
        POWERTOOLS_TRACE_ENABLED                 = tostring(var.config.tracing_config.mode != null)
        POWERTOOLS_TRACER_CAPTURE_HTTPS_REQUESTS = tostring(var.config.tracing_config.capture_http_requests)
        POWERTOOLS_TRACER_CAPTURE_ERROR          = tostring(var.config.tracing_config.capture_error)
        POWERTOOLS_METRICS_NAMESPACE             = var.config.metrics != null ? var.config.metrics.namespace : "GitHub Runners"
        ENABLE_RUNNER_DEREGISTRATION             = "true"
        DEREGISTER_RETRY_QUEUE_URL               = aws_sqs_queue.deregister_retry[0].url
      },
      local.deregistration_env_vars
    )
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.deregister_retry[0].name
  }

  dynamic "vpc_config" {
    for_each = length(var.config.subnet_ids) > 0 && length(var.config.security_group_ids) > 0 ? [true] : []
    content {
      security_group_ids = var.config.security_group_ids
      subnet_ids         = var.config.subnet_ids
    }
  }

  dynamic "tracing_config" {
    for_each = var.config.tracing_config.mode != null ? [true] : []
    content {
      mode = var.config.tracing_config.mode
    }
  }

  tags = merge(var.config.tags, var.config.lambda_tags)
}

# ─── Event source mapping: SQS → deregister-retry Lambda ─────────────────────

resource "aws_lambda_event_source_mapping" "deregister_retry" {
  count = local.enable_runner_deregistration && var.config.enable_deregister_retry ? 1 : 0

  event_source_arn = aws_sqs_queue.deregister_retry[0].arn
  function_name    = aws_lambda_function.deregister_retry[0].arn
  batch_size       = 1 # Process one message at a time to isolate failures per runner
  enabled          = true
}

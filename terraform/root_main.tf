module "terraform_config_hosting_project" {
  source  = "./da-terraform-configurations/"
  project = var.hosting_project
}

module "shared_configurations_talend" {
  source = "./da-terraform-configurations/talend"
}

module "aws_backup_terraform_config" {
  source  = "./da-terraform-configurations/"
  project = "aws-backup"
}

module "dynamodb" {
  source                         = "./da-terraform-modules/dynamo"
  table_name                     = local.reference_counter_table_name
  hash_key                       = { type : "S", name : local.dynamodb_hash_key }
  deletion_protection_enabled    = true
  server_side_encryption_enabled = true
  kms_key_arn                    = module.dynamodb_kms_key.kms_key_arn
  point_in_time_recovery_enabled = true
  common_tags                    = merge(local.hosting_common_tags, local.aws_backup_tag)
}

module "dynamodb_kms_key" {
  source   = "./da-terraform-modules/kms"
  key_name = "${var.project}-reference-counter-key-${local.hosting_environment}"
  tags     = local.hosting_common_tags
  default_policy_variables = {
    user_roles           = [module.reference_generator_lambda.lambda_role_arn]
    user_roles_decoupled = local.aws_backup_roles
    ci_roles             = [local.hosting_assume_role]
    service_details = [
      {
        service_name : "cloudwatch"
        service_source_account : data.aws_caller_identity.current.account_id
      }
    ]
    wiz_roles = local.wiz_role_arns
  }
}

module "reference_generator_lambda" {
  source        = "./da-terraform-modules/lambda"
  function_name = local.reference_generator_function_name
  handler       = "uk.gov.nationalarchives.referencegenerator.Lambda::handleRequest"
  policies = {
    "${upper(var.project)}ReferenceGeneratorLambdaPolicy${title(local.hosting_environment)}" = templatefile("${path.module}/templates/lambda/reference_generator_policy.json.tpl", {
      function_name = local.reference_generator_function_name
      account_id    = data.aws_caller_identity.current.account_id
      table_name    = local.reference_counter_table_name
      kms_key_arn   = module.dynamodb_kms_key.kms_key_arn
    })
  }
  plaintext_env_vars = {
    ENVIRONMENT         = local.hosting_environment
    TABLE_NAME          = "${var.project}-reference-counter"
    REFERENCE_KEY       = "v1"
    REFERENCE_KEY_VALUE = "fileCounter"
    REFERENCE_COUNTER   = "referenceCounter"
    QUERY_PARAM         = "numberofrefs"
    REFERENCE_LIMIT     = local.reference_generator_limit
    REFERENCE_RETRIES   = local.reference_generator_retries
  }
  runtime         = "java17"
  timeout_seconds = 60
  memory_size     = 1024
  tags            = local.hosting_common_tags
  lambda_invoke_permissions = {
    "apigateway.amazonaws.com" = "${module.reference_generator_api_gateway.api_execution_arn}/*/GET/counter"
  }
}

module "reference_generator_api_gateway" {
  source = "./da-terraform-modules/apigateway"
  api_definition = templatefile("./templates/api_gateway/reference_generator.json.tpl", {
    environment = local.hosting_environment
    title       = local.reference_generator_api_gateway_name
    lambda_arn  = module.reference_generator_lambda.lambda_arn,
  })
  api_name    = local.reference_generator_api_gateway_name
  environment = local.hosting_environment
  common_tags = local.hosting_common_tags
  api_rest_policy = templatefile("${path.module}/templates/api_gateway/reference_generator_rest_policy.json.tpl", {
    api_gateway_arn   = module.reference_generator_api_gateway.api_execution_arn
    tdr_vpc_public_ip = jsonencode(local.tdr_vpc_public_ip)
  })
  api_method_settings = [{
    method_path        = "*/*"
    logging_level      = "INFO",
    metrics_enabled    = false,
    data_trace_enabled = false
  }]
}

locals {
  allowed_vpces_tdr = {
    intg = [
      "${module.shared_configurations_talend.config.dev.api_gateway_vpce}",
      "${module.shared_configurations_talend.config.intg.api_gateway_vpce}"
    ]
    staging = ["${module.shared_configurations_talend.config.staging.api_gateway_vpce}"]
    prod    = ["${module.shared_configurations_talend.config.prod.api_gateway_vpce}"]
    dev     = []
  }
}

module "reference_generator_api_gateway_private" {
  source                 = "./da-terraform-modules/apigateway"
  endpoint_configuration = { "types" : ["PRIVATE"] }
  api_definition = templatefile("./templates/api_gateway/reference_generator.json.tpl", {
    environment = local.hosting_environment
    title       = format("%s-%s", local.reference_generator_api_gateway_name, "private")
    lambda_arn  = module.reference_generator_lambda.lambda_arn,
  })
  api_name    = format("%s-%s", local.reference_generator_api_gateway_name, "private")
  environment = local.hosting_environment
  common_tags = local.hosting_common_tags
  api_rest_policy = templatefile("${path.module}/templates/api_gateway/reference_generator_rest_policy_private.json.tpl", {
    api_gateway_arn = module.reference_generator_api_gateway_private.api_execution_arn

    allowed_vpces = jsonencode(local.allowed_vpces_tdr[local.hosting_environment])
  })
  api_method_settings = [{
    method_path        = "*/*"
    logging_level      = "INFO",
    metrics_enabled    = false,
    data_trace_enabled = false
  }]
}

# The da-terraform-modules/lambda can only accept a map so duplicate principal names are not possible
# Add the permission just for the private API
resource "aws_lambda_permission" "lambda_permissions" {
  statement_id  = "AllowExecutionFromApigatewayPrivate"
  action        = "lambda:InvokeFunction"
  function_name = module.reference_generator_lambda.lambda_function.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${module.reference_generator_api_gateway_private.api_execution_arn}/*/GET/counter"
}

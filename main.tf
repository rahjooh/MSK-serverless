# CloudWatch log group for broker logs
resource "aws_cloudwatch_log_group" "msk_broker" {
  count             = var.existing_broker_log_group_name == null ? 1 : 0
  name              = local.broker_log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = merge(var.tags, { AccessScope = var.access_scope })
}

data "aws_cloudwatch_log_group" "existing_msk_broker" {
  count = var.existing_broker_log_group_name != null ? 1 : 0
  name  = var.existing_broker_log_group_name
}

# --- Collector Security Group (for EC2 producers) ---
resource "aws_security_group" "collector" {
  count       = var.existing_collector_security_group_id == null ? 1 : 0
  name        = local.collector_sg_name
  description = var.collector_sg_description
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = var.collector_sg_egress_cidrs
  }

  tags = merge(var.tags, { AccessScope = var.access_scope })
}

data "aws_security_group" "existing_collector" {
  count = var.existing_collector_security_group_id != null ? 1 : 0
  id    = var.existing_collector_security_group_id
}

# --- Consumer Security Group ---
resource "aws_security_group" "consumers" {
  count       = var.existing_consumer_security_group_id == null ? 1 : 0
  name        = local.consumer_sg_name
  description = var.consumer_sg_description
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { AccessScope = var.access_scope })
}

data "aws_security_group" "existing_consumers" {
  count = var.existing_consumer_security_group_id != null ? 1 : 0
  id    = var.existing_consumer_security_group_id
}

# --- MSK Brokers Security Group ---
resource "aws_security_group" "msk_brokers" {
  count       = var.existing_msk_broker_security_group_id == null ? 1 : 0
  name        = local.msk_broker_sg_name
  description = "MSK Serverless broker SG"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { AccessScope = var.access_scope })
}

data "aws_security_group" "existing_msk_brokers" {
  count = var.existing_msk_broker_security_group_id != null ? 1 : 0
  id    = var.existing_msk_broker_security_group_id
}

locals {
  collector_security_group_id = coalesce(
    try(aws_security_group.collector[0].id, null),
    try(data.aws_security_group.existing_collector[0].id, null)
  )

  consumers_security_group_id = coalesce(
    try(aws_security_group.consumers[0].id, null),
    try(data.aws_security_group.existing_consumers[0].id, null)
  )

  msk_broker_security_group_id = coalesce(
    try(aws_security_group.msk_brokers[0].id, null),
    try(data.aws_security_group.existing_msk_brokers[0].id, null)
  )
}

# Allow all egress from brokers (outbound)
resource "aws_vpc_security_group_egress_rule" "msk_all_egress" {
  security_group_id = local.msk_broker_security_group_id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Broker outbound"
}

# Allow SASL/IAM TLS (9098) from collector SG -> brokers
resource "aws_vpc_security_group_ingress_rule" "msk_iam_9098_from_collector" {
  security_group_id            = local.msk_broker_security_group_id
  description                  = "Collector-to-broker SASL/IAM TLS within VPC"
  ip_protocol                  = "tcp"
  from_port                    = 9098
  to_port                      = 9098
  referenced_security_group_id = local.collector_security_group_id
}

# Allow SASL/IAM TLS (9098) from consumers SG -> brokers
resource "aws_vpc_security_group_ingress_rule" "msk_iam_9098_from_consumers" {
  security_group_id            = local.msk_broker_security_group_id
  description                  = "Consumer-to-broker SASL/IAM TLS within VPC"
  ip_protocol                  = "tcp"
  from_port                    = 9098
  to_port                      = 9098
  referenced_security_group_id = local.consumers_security_group_id
}

# --- MSK Serverless cluster ---
resource "aws_msk_serverless_cluster" "this" {
  cluster_name = local.cluster_name

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [local.msk_broker_security_group_id]
  }

  client_authentication {
    sasl {
      iam { enabled = true } # IAM auth (TLS :9098)
    }
  }

  tags = merge(var.tags, { AccessScope = var.access_scope })
}

# CloudWatch log group for broker logs
resource "aws_cloudwatch_log_group" "msk_broker" {
  name              = local.broker_log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = merge(var.tags, { AccessScope = var.access_scope })
}

# --- Collector Security Group (for EC2 producers) ---
resource "aws_security_group" "collector" {
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

# --- Consumer Security Group ---
resource "aws_security_group" "consumers" {
  name        = local.consumer_sg_name
  description = var.consumer_sg_description
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { AccessScope = var.access_scope })
}

# --- MSK Brokers Security Group ---
resource "aws_security_group" "msk_brokers" {
  name        = local.msk_broker_sg_name
  description = "MSK Serverless broker SG"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { AccessScope = var.access_scope })
}

# Allow all egress from brokers (outbound)
resource "aws_vpc_security_group_egress_rule" "msk_all_egress" {
  security_group_id = aws_security_group.msk_brokers.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Broker outbound"
}

# Allow SASL/IAM TLS (9098) from collector SG -> brokers
resource "aws_vpc_security_group_ingress_rule" "msk_iam_9098_from_collector" {
  security_group_id            = aws_security_group.msk_brokers.id
  description                  = "Collector-to-broker SASL/IAM TLS within VPC"
  ip_protocol                  = "tcp"
  from_port                    = 9098
  to_port                      = 9098
  referenced_security_group_id = aws_security_group.collector.id
}

# Allow SASL/IAM TLS (9098) from consumers SG -> brokers
resource "aws_vpc_security_group_ingress_rule" "msk_iam_9098_from_consumers" {
  security_group_id            = aws_security_group.msk_brokers.id
  description                  = "Consumer-to-broker SASL/IAM TLS within VPC"
  ip_protocol                  = "tcp"
  from_port                    = 9098
  to_port                      = 9098
  referenced_security_group_id = aws_security_group.consumers.id
}

# --- MSK Serverless cluster ---
resource "aws_msk_serverless_cluster" "this" {
  cluster_name = local.cluster_name

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.msk_brokers.id]
  }

  client_authentication {
    sasl {
      iam { enabled = true } # IAM auth (TLS :9098)
    }
  }

  tags = merge(var.tags, { AccessScope = var.access_scope })
}

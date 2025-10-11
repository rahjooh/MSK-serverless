locals {
  infrastructure_summary = {
    msk_cluster = {
      arn                        = aws_msk_serverless_cluster.this.arn
      cluster_uuid               = aws_msk_serverless_cluster.this.cluster_uuid
      bootstrap_brokers_sasl_iam = aws_msk_serverless_cluster.this.bootstrap_brokers_sasl_iam
      security_group_ids         = aws_msk_serverless_cluster.this.vpc_config[0].security_group_ids
      subnet_ids                 = aws_msk_serverless_cluster.this.vpc_config[0].subnet_ids
      tags                       = aws_msk_serverless_cluster.this.tags
    }
    cloudwatch = {
      log_group_name = coalesce(
        try(aws_cloudwatch_log_group.msk_broker[0].name, null),
        try(data.aws_cloudwatch_log_group.existing_msk_broker[0].name, null)
      )
      log_group_arn = coalesce(
        try(aws_cloudwatch_log_group.msk_broker[0].arn, null),
        try(data.aws_cloudwatch_log_group.existing_msk_broker[0].arn, null)
      )
      retention_days = coalesce(
        try(aws_cloudwatch_log_group.msk_broker[0].retention_in_days, null),
        try(data.aws_cloudwatch_log_group.existing_msk_broker[0].retention_in_days, null)
      )
    }
    security_groups = {
      collectors = {
        id = coalesce(
          try(aws_security_group.collector[0].id, null),
          try(data.aws_security_group.existing_collector[0].id, null)
        )
        arn = coalesce(
          try(aws_security_group.collector[0].arn, null),
          try(data.aws_security_group.existing_collector[0].arn, null)
        )
        tags = coalesce(
          try(aws_security_group.collector[0].tags, null),
          try(data.aws_security_group.existing_collector[0].tags, null)
        )
      }
      consumers = {
        id = coalesce(
          try(aws_security_group.consumers[0].id, null),
          try(data.aws_security_group.existing_consumers[0].id, null)
        )
        arn = coalesce(
          try(aws_security_group.consumers[0].arn, null),
          try(data.aws_security_group.existing_consumers[0].arn, null)
        )
        tags = coalesce(
          try(aws_security_group.consumers[0].tags, null),
          try(data.aws_security_group.existing_consumers[0].tags, null)
        )
      }
      msk_brokers = {
        id = coalesce(
          try(aws_security_group.msk_brokers[0].id, null),
          try(data.aws_security_group.existing_msk_brokers[0].id, null)
        )
        arn = coalesce(
          try(aws_security_group.msk_brokers[0].arn, null),
          try(data.aws_security_group.existing_msk_brokers[0].arn, null)
        )
        tags = coalesce(
          try(aws_security_group.msk_brokers[0].tags, null),
          try(data.aws_security_group.existing_msk_brokers[0].tags, null)
        )
      }
      ingress_rules = [
        {
          key                          = "collectors"
          id                           = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_collector.id
          arn                          = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_collector.arn
          referenced_security_group_id = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_collector.referenced_security_group_id
          description                  = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_collector.description
          from_port                    = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_collector.from_port
          to_port                      = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_collector.to_port
          protocol                     = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_collector.ip_protocol
        },
        {
          key                          = "consumers"
          id                           = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_consumers.id
          arn                          = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_consumers.arn
          referenced_security_group_id = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_consumers.referenced_security_group_id
          description                  = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_consumers.description
          from_port                    = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_consumers.from_port
          to_port                      = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_consumers.to_port
          protocol                     = aws_vpc_security_group_ingress_rule.msk_iam_9098_from_consumers.ip_protocol
        }
      ]
      egress_rule = {
        id                     = aws_vpc_security_group_egress_rule.msk_all_egress.id
        arn                    = aws_vpc_security_group_egress_rule.msk_all_egress.arn
        cidr_ipv4              = aws_vpc_security_group_egress_rule.msk_all_egress.cidr_ipv4
        ip_protocol            = aws_vpc_security_group_egress_rule.msk_all_egress.ip_protocol
        security_group_rule_id = aws_vpc_security_group_egress_rule.msk_all_egress.security_group_rule_id
      }
    }
    iam = {
      roles = {
        collector = {
          name = local.collector_role_resolved_name
          arn  = local.collector_role_resolved_arn
        }
      }
      instance_profiles = {
        collector = {
          name = local.collector_instance_profile_resolved_name
          arn  = local.collector_instance_profile_resolved_arn
        }
      }
      policies = {
        msk_control_plane = {
          name = local.msk_control_policy_resolved_name
          arn  = local.msk_control_policy_resolved_arn
        }
        producer = {
          name = local.producer_policy_resolved_name
          arn  = local.producer_policy_resolved_arn
        }
        consumer = {
          name = local.consumer_policy_resolved_name
          arn  = local.consumer_policy_resolved_arn
        }
      }
      attachments = {
        collector_control = {
          role_name  = aws_iam_role_policy_attachment.collector_control_attach.role
          policy_arn = aws_iam_role_policy_attachment.collector_control_attach.policy_arn
        }
        collector_producer = {
          role_name  = aws_iam_role_policy_attachment.collector_producer_attach.role
          policy_arn = aws_iam_role_policy_attachment.collector_producer_attach.policy_arn
        }
      }
    }
  }
}

output "msk_cluster_arn" {
  value       = aws_msk_serverless_cluster.this.arn
  description = "MSK Serverless cluster ARN"
}

output "msk_cluster_uuid" {
  value       = aws_msk_serverless_cluster.this.cluster_uuid
  description = "UUID used in Kafka ARNs"
}

output "bootstrap_brokers_sasl_iam" {
  value       = aws_msk_serverless_cluster.this.bootstrap_brokers_sasl_iam
  description = "Comma-separated brokers for SASL/IAM (TLS :9098)"
}

output "msk_broker_security_group_id" {
  value = coalesce(
    try(aws_security_group.msk_brokers[0].id, null),
    try(data.aws_security_group.existing_msk_brokers[0].id, null)
  )
  description = "Security group ID for MSK brokers"
}

output "collector_instance_profile_name" {
  value       = local.collector_instance_profile_resolved_name
  description = "Attach this instance profile to your EC2 collectors"
}

output "consumer_policy_arn" {
  value       = local.consumer_policy_resolved_arn
  description = "Attach this to consumer roles in other teams"
}

output "collector_sg_id" {
  value = coalesce(
    try(aws_security_group.collector[0].id, null),
    try(data.aws_security_group.existing_collector[0].id, null)
  )
  description = "Security Group ID created for EC2 collectors"
}

output "consumer_sg_id" {
  value = coalesce(
    try(aws_security_group.consumers[0].id, null),
    try(data.aws_security_group.existing_consumers[0].id, null)
  )
  description = "Security Group ID created for MSK consumers"
}

output "infrastructure_summary_json" {
  description = "JSON summary of the AWS resources created by this configuration"
  value       = local.infrastructure_summary
}

resource "local_file" "infrastructure_summary" {
  content  = jsonencode(local.infrastructure_summary)
  filename = "${path.module}/resources.json"
}

locals {
  naming_config = yamldecode(file("${path.module}/naming.yml"))

  cluster_name = coalesce(
    var.cluster_name,
    try(local.naming_config.cluster.name, null),
    "msk-crypto-cluster"
  )

  collector_sg_name = coalesce(
    var.collector_sg_name,
    try(local.naming_config.security_groups.collector.name, null),
    "msk-crypto-sg-collectors"
  )

  consumer_sg_name = coalesce(
    var.consumer_sg_name,
    try(local.naming_config.security_groups.consumer.name, null),
    "msk-crypto-sg-consumers"
  )

  msk_broker_sg_name = coalesce(
    try(local.naming_config.security_groups.brokers.name, null),
    "msk-crypto-sg-brokers"
  )

  broker_log_group_name = coalesce(
    try(local.naming_config.cloudwatch.broker_log_group.name, null),
    "msk-crypto-cw-lg-broker"
  )

  collector_role_name = coalesce(
    try(local.naming_config.iam.collector_role.name, null),
    "msk-crypto-iam-collector"
  )

  collector_instance_profile_name = coalesce(
    try(local.naming_config.iam.instance_profile.name, null),
    local.collector_role_name
  )

  msk_control_policy_name = coalesce(
    try(local.naming_config.iam.control_plane_policy.name, null),
    "msk-crypto-iam-control"
  )

  producer_policy_name = coalesce(
    try(local.naming_config.iam.producer_policy.name, null),
    "msk-crypto-iam-producer"
  )

  consumer_policy_name = coalesce(
    try(local.naming_config.iam.consumer_policy.name, null),
    "msk-crypto-iam-consumer"
  )
}

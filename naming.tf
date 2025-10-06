locals {
  naming_config = yamldecode(file("${path.module}/naming.yml"))

  cluster_name = coalesce(
    var.cluster_name,
    try(local.naming_config.cluster.name, null)
  )

  collector_sg_name = coalesce(
    var.collector_sg_name,
    try(local.naming_config.security_groups.collector.name, null),
    "msk_collectors"
  )

  consumer_sg_name = coalesce(
    var.consumer_sg_name,
    try(local.naming_config.security_groups.consumer.name, null),
    "msk_consumers"
  )

  msk_broker_sg_name = coalesce(
    try(local.naming_config.security_groups.brokers.name, null),
    "${local.cluster_name}_brokers"
  )

  broker_log_group_name = coalesce(
    try(local.naming_config.cloudwatch.broker_log_group.name, null),
    "${local.cluster_name}_broker"
  )

  collector_role_name = coalesce(
    try(local.naming_config.iam.collector_role.name, null),
    "${local.cluster_name}_collector"
  )

  collector_instance_profile_name = coalesce(
    try(local.naming_config.iam.instance_profile.name, null),
    local.collector_role_name
  )

  msk_control_policy_name = coalesce(
    try(local.naming_config.iam.control_plane_policy.name, null),
    "${local.cluster_name}_msk_control"
  )

  producer_policy_name = coalesce(
    try(local.naming_config.iam.producer_policy.name, null),
    "${local.cluster_name}_producer"
  )

  consumer_policy_name = coalesce(
    try(local.naming_config.iam.consumer_policy.name, null),
    "${local.cluster_name}_consumer"
  )
}

# Validate naming conventions sourced from YAML/variables
locals {
  _cluster_name_validation = regex("^msk-[A-Za-z0-9-]+$", local.cluster_name)
  _collector_sg_validation = regex("^msk[-_]", local.collector_sg_name)
  _consumer_sg_validation  = regex("^msk[-_]", local.consumer_sg_name)
}

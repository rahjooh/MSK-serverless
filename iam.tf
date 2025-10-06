locals {
  region       = var.region
  account_id   = data.aws_caller_identity.this.account_id
  cluster_arn  = aws_msk_serverless_cluster.this.arn
  cluster_uuid = aws_msk_serverless_cluster.this.cluster_uuid

  # Kafka ARNs:
  # arn:aws:kafka:<region>:<acct>:topic/<cluster-name>/<uuid>/<topic>
  producer_topic_arns = [
    for p in var.producer_topic_prefixes :
    "arn:aws:kafka:${local.region}:${local.account_id}:topic/${local.cluster_name}/${local.cluster_uuid}/${p}*"
  ]

  consumer_topic_arns = [
    for p in var.consumer_topic_prefixes :
    "arn:aws:kafka:${local.region}:${local.account_id}:topic/${local.cluster_name}/${local.cluster_uuid}/${p}*"
  ]

  # arn:aws:kafka:<region>:<acct>:group/<cluster-name>/<uuid>/<group>
  consumer_group_arns = [
    for g in var.consumer_group_names :
    "arn:aws:kafka:${local.region}:${local.account_id}:group/${local.cluster_name}/${local.cluster_uuid}/${g}"
  ]
}

# ---- EC2 collectors (producers) ----

# Trust policy for EC2
data "aws_iam_policy_document" "collector_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "collector_role" {
  provider             = aws.untagged
  name                 = local.collector_role_name
  assume_role_policy   = data.aws_iam_policy_document.collector_assume.json
  permissions_boundary = var.pb_arn
}

resource "aws_iam_instance_profile" "collector_profile" {
  provider = aws.untagged
  name     = local.collector_instance_profile_name
  role     = aws_iam_role.collector_role.name
}

# Control-plane permissions (fetch bootstrap brokers, describe cluster)
data "aws_iam_policy_document" "msk_control_plane" {
  statement {
    effect = "Allow"
    actions = [
      "kafka:GetBootstrapBrokers",
      "kafka:DescribeCluster",
      "kafka:DescribeClusterV2"
    ]
    resources = [local.cluster_arn]
  }
}

resource "aws_iam_policy" "msk_control_plane" {
  provider = aws.untagged
  name     = local.msk_control_policy_name
  policy   = data.aws_iam_policy_document.msk_control_plane.json
}

# Producer data-plane permissions
data "aws_iam_policy_document" "producer" {
  statement {
    sid    = "ConnectCluster"
    effect = "Allow"
    actions = [
      "kafka-cluster:Connect",
      "kafka-cluster:WriteDataIdempotently"
    ]
    resources = [local.cluster_arn]
  }

  statement {
    sid    = "WriteToTopics"
    effect = "Allow"
    actions = [
      "kafka-cluster:DescribeTopic",
      "kafka-cluster:WriteData",
      "kafka-cluster:CreateTopic"
    ]
    resources = local.producer_topic_arns
  }
}

resource "aws_iam_policy" "producer" {
  provider = aws.untagged
  name     = local.producer_policy_name
  policy   = data.aws_iam_policy_document.producer.json
}

resource "aws_iam_role_policy_attachment" "collector_control_attach" {
  role       = aws_iam_role.collector_role.name
  policy_arn = aws_iam_policy.msk_control_plane.arn
}

resource "aws_iam_role_policy_attachment" "collector_producer_attach" {
  role       = aws_iam_role.collector_role.name
  policy_arn = aws_iam_policy.producer.arn
}

# ---- Consumer policy (attach this to other teams' roles) ----
data "aws_iam_policy_document" "consumer" {
  statement {
    sid       = "ConnectCluster"
    effect    = "Allow"
    actions   = ["kafka-cluster:Connect"]
    resources = [local.cluster_arn]
  }

  statement {
    sid    = "ReadFromTopics"
    effect = "Allow"
    actions = [
      "kafka-cluster:DescribeTopic",
      "kafka-cluster:ReadData"
    ]
    resources = local.consumer_topic_arns
  }

  statement {
    sid    = "GroupMembership"
    effect = "Allow"
    actions = [
      "kafka-cluster:DescribeGroup",
      "kafka-cluster:AlterGroup",
      "kafka-cluster:DeleteGroup"
    ]
    resources = local.consumer_group_arns
  }
}

resource "aws_iam_policy" "consumer" {
  provider = aws.untagged
  name     = local.consumer_policy_name
  policy   = data.aws_iam_policy_document.consumer.json
}

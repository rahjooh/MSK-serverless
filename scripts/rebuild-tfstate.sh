#!/usr/bin/env bash
set -euo pipefail

# Optional verbose debugging
if [ "${STATE_DEBUG:-}" = "1" ]; then
  set -x
fi

if ! command -v terraform >/dev/null 2>&1; then
  if [ -n "${TERRAFORM_CLI_PATH:-}" ]; then
    if [ -d "$TERRAFORM_CLI_PATH" ]; then
      PATH="$TERRAFORM_CLI_PATH:$PATH"
    elif [ -x "$TERRAFORM_CLI_PATH" ]; then
      PATH="$(dirname "$TERRAFORM_CLI_PATH"):$PATH"
    fi
  fi
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform CLI is required" >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required" >&2
  exit 1
fi

# Python is used to parse naming.yml and emit defaults
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

: "${TF_BACKEND_BUCKET:?Environment variable TF_BACKEND_BUCKET must be set}"
: "${TF_BACKEND_KEY:?Environment variable TF_BACKEND_KEY must be set}"

BACKEND_REGION="${TF_BACKEND_REGION:-${AWS_REGION:-${TF_VAR_region:-}}}"
if [ -z "$BACKEND_REGION" ]; then
  echo "Set TF_BACKEND_REGION, AWS_REGION or TF_VAR_region so the backend region can be determined" >&2
  exit 1
fi

AWS_REGION_EFFECTIVE="${AWS_REGION:-${TF_VAR_region:-}}"
if [ -z "$AWS_REGION_EFFECTIVE" ]; then
  echo "Set AWS_REGION or TF_VAR_region to target the correct AWS region" >&2
  exit 1
fi
export AWS_REGION="$AWS_REGION_EFFECTIVE"

: "${TF_VAR_vpc_id:?Environment variable TF_VAR_vpc_id must be set (for filtering existing security groups)}"
: "${TF_VAR_subnet_ids:?Environment variable TF_VAR_subnet_ids must be set (JSON encoded list)}"

NAME_DEFAULTS="$(python3 - <<'PY'
import pathlib
import sys

def shell_escape(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"

path = pathlib.Path('naming.yml')
raw_data = {}

if path.exists():
    content = path.read_text().splitlines()
    stack = [(-2, raw_data)]
    for raw_line in content:
        stripped = raw_line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(' '))
        key, sep, value = stripped.partition(':')
        if not sep:
            continue
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        value = value.strip()
        if value:
            if value.startswith('"') and value.endswith('"') and len(value) >= 2:
                value = value[1:-1]
            parent[key] = value
        else:
            new_map = {}
            parent[key] = new_map
            stack.append((indent, new_map))

def dig(obj, *keys):
    cur = obj
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
    return cur

cluster_name_default = dig(raw_data, 'cluster', 'name') or 'msk-crypto-cluster'
collector_sg_name_default = dig(raw_data, 'security_groups', 'collector', 'name') or 'msk-crypto-sg-collectors'
consumer_sg_name_default = dig(raw_data, 'security_groups', 'consumer', 'name') or 'msk-crypto-sg-consumers'
msk_broker_sg_name_default = dig(raw_data, 'security_groups', 'brokers', 'name') or 'msk-crypto-sg-brokers'
broker_log_group_name_default = dig(raw_data, 'cloudwatch', 'broker_log_group', 'name') or 'msk-crypto-cw-lg-broker'
collector_role_name_default = dig(raw_data, 'iam', 'collector_role', 'name') or 'msk-crypto-iam-collector'
collector_instance_profile_name_default = dig(raw_data, 'iam', 'instance_profile', 'name') or collector_role_name_default
msk_control_policy_name_default = dig(raw_data, 'iam', 'control_plane_policy', 'name') or 'msk-crypto-iam-control'
producer_policy_name_default = dig(raw_data, 'iam', 'producer_policy', 'name') or 'msk-crypto-iam-producer'
consumer_policy_name_default = dig(raw_data, 'iam', 'consumer_policy', 'name') or 'msk-crypto-iam-consumer'

values = {
    'cluster_name_default': cluster_name_default,
    'collector_sg_name_default': collector_sg_name_default,
    'consumer_sg_name_default': consumer_sg_name_default,
    'msk_broker_sg_name_default': msk_broker_sg_name_default,
    'broker_log_group_name_default': broker_log_group_name_default,
    'collector_role_name_default': collector_role_name_default,
    'collector_instance_profile_name_default': collector_instance_profile_name_default,
    'msk_control_policy_name_default': msk_control_policy_name_default,
    'producer_policy_name_default': producer_policy_name_default,
    'consumer_policy_name_default': consumer_policy_name_default,
}

for key, value in values.items():
    print(f"{key}={shell_escape(value)}")
PY
)"

eval "$NAME_DEFAULTS"

CLUSTER_NAME="${TF_VAR_cluster_name:-$cluster_name_default}"
COLLECTOR_SG_NAME="${TF_VAR_collector_sg_name:-$collector_sg_name_default}"
CONSUMER_SG_NAME="${TF_VAR_consumer_sg_name:-$consumer_sg_name_default}"
MSK_BROKER_SG_NAME="$msk_broker_sg_name_default"
BROKER_LOG_GROUP_NAME="$broker_log_group_name_default"
COLLECTOR_ROLE_NAME="$collector_role_name_default"
COLLECTOR_INSTANCE_PROFILE_NAME="$collector_instance_profile_name_default"
MSK_CONTROL_POLICY_NAME="$msk_control_policy_name_default"
PRODUCER_POLICY_NAME="$producer_policy_name_default"
CONSUMER_POLICY_NAME="$consumer_policy_name_default"

BACKEND_ARGS=(
  "-backend-config=bucket=${TF_BACKEND_BUCKET}"
  "-backend-config=key=${TF_BACKEND_KEY}"
  "-backend-config=region=${BACKEND_REGION}"
)

if [ -n "${TF_BACKEND_DYNAMODB_TABLE:-}" ]; then
  BACKEND_ARGS+=("-backend-config=dynamodb_table=${TF_BACKEND_DYNAMODB_TABLE}")
fi

terraform init -input=false -reconfigure "${BACKEND_ARGS[@]}"

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
if [ "$ACCOUNT_ID" = "None" ] || [ -z "$ACCOUNT_ID" ]; then
  echo "Unable to determine AWS account ID" >&2
  exit 1
fi

CONTROL_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${MSK_CONTROL_POLICY_NAME}"
PRODUCER_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${PRODUCER_POLICY_NAME}"
CONSUMER_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${CONSUMER_POLICY_NAME}"

VPC_ID="$TF_VAR_vpc_id"

lookup_sg_id() {
  local name="$1"
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text
}

missing_resources=()

record_missing() {
  local description="$1"
  missing_resources+=("$description")
  echo "Skipping ${description}" >&2
}

is_missing() {
  local value="$1"
  [ -z "$value" ] || [ "$value" = "None" ]
}

safe_import() {
  local address="$1"
  local identifier="$2"
  local description="$3"
  if is_missing "$identifier"; then
    record_missing "$description (identifier not found)"
    return
  fi
  if terraform import "$address" "$identifier"; then
    return
  fi
  record_missing "$description (terraform import failed)"
}

COLLECTOR_SG_ID=$(lookup_sg_id "$COLLECTOR_SG_NAME")
if is_missing "$COLLECTOR_SG_ID"; then
  record_missing "collector security group ${COLLECTOR_SG_NAME} in VPC ${VPC_ID}"
fi

CONSUMER_SG_ID=$(lookup_sg_id "$CONSUMER_SG_NAME")
if is_missing "$CONSUMER_SG_ID"; then
  record_missing "consumer security group ${CONSUMER_SG_NAME} in VPC ${VPC_ID}"
fi

MSK_BROKER_SG_ID=$(lookup_sg_id "$MSK_BROKER_SG_NAME")
if is_missing "$MSK_BROKER_SG_ID"; then
  record_missing "MSK broker security group ${MSK_BROKER_SG_NAME} in VPC ${VPC_ID}"
fi

COLLECTOR_RULE_ID=""
if ! is_missing "$MSK_BROKER_SG_ID" && ! is_missing "$COLLECTOR_SG_ID"; then
  COLLECTOR_RULE_ID=$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=${MSK_BROKER_SG_ID}" \
              "Name=referenced-group-id,Values=${COLLECTOR_SG_ID}" \
              "Name=ip-protocol,Values=tcp" \
              "Name=from-port,Values=9098" \
              "Name=to-port,Values=9098" \
    --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text)
  if is_missing "$COLLECTOR_RULE_ID"; then
    record_missing "security group ingress rule for collectors -> brokers"
  fi
fi

CONSUMER_RULE_ID=""
if ! is_missing "$MSK_BROKER_SG_ID" && ! is_missing "$CONSUMER_SG_ID"; then
  CONSUMER_RULE_ID=$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=${MSK_BROKER_SG_ID}" \
              "Name=referenced-group-id,Values=${CONSUMER_SG_ID}" \
              "Name=ip-protocol,Values=tcp" \
              "Name=from-port,Values=9098" \
              "Name=to-port,Values=9098" \
    --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text)
  if is_missing "$CONSUMER_RULE_ID"; then
    record_missing "security group ingress rule for consumers -> brokers"
  fi
fi

EGRESS_RULE_ID=""
if ! is_missing "$MSK_BROKER_SG_ID"; then
  EGRESS_RULE_ID=$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=${MSK_BROKER_SG_ID}" \
              "Name=is-egress,Values=true" \
              "Name=ip-protocol,Values=-1" \
              "Name=cidr,Values=0.0.0.0/0" \
    --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text)
  if is_missing "$EGRESS_RULE_ID"; then
    record_missing "security group egress rule for brokers"
  fi
fi

CLUSTER_ARN=$(aws kafka list-clusters-v2 --cluster-name-filter "${CLUSTER_NAME}" \
  --query 'ClusterInfoList[0].ClusterArn' --output text)
if is_missing "$CLUSTER_ARN"; then
  record_missing "MSK Serverless cluster named ${CLUSTER_NAME}"
fi

echo "Importing CloudWatch log group ${BROKER_LOG_GROUP_NAME}" >&2
safe_import "aws_cloudwatch_log_group.msk_broker" "${BROKER_LOG_GROUP_NAME}" "CloudWatch log group ${BROKER_LOG_GROUP_NAME}"

echo "Importing security groups" >&2
if ! is_missing "$COLLECTOR_SG_ID"; then
  safe_import "aws_security_group.collector" "${COLLECTOR_SG_ID}" "collector security group ${COLLECTOR_SG_NAME}"
fi
if ! is_missing "$CONSUMER_SG_ID"; then
  safe_import "aws_security_group.consumers" "${CONSUMER_SG_ID}" "consumer security group ${CONSUMER_SG_NAME}"
fi
if ! is_missing "$MSK_BROKER_SG_ID"; then
  safe_import "aws_security_group.msk_brokers" "${MSK_BROKER_SG_ID}" "MSK broker security group ${MSK_BROKER_SG_NAME}"
fi

echo "Importing security group rules" >&2
if ! is_missing "$COLLECTOR_RULE_ID"; then
  safe_import "aws_vpc_security_group_ingress_rule.msk_iam_9098_from_collector" "${COLLECTOR_RULE_ID}" "collector -> broker security group rule"
fi
if ! is_missing "$CONSUMER_RULE_ID"; then
  safe_import "aws_vpc_security_group_ingress_rule.msk_iam_9098_from_consumers" "${CONSUMER_RULE_ID}" "consumer -> broker security group rule"
fi
if ! is_missing "$EGRESS_RULE_ID"; then
  safe_import "aws_vpc_security_group_egress_rule.msk_all_egress" "${EGRESS_RULE_ID}" "broker egress security group rule"
fi

echo "Importing MSK Serverless cluster" >&2
if ! is_missing "$CLUSTER_ARN"; then
  safe_import "aws_msk_serverless_cluster.this" "${CLUSTER_ARN}" "MSK Serverless cluster ${CLUSTER_NAME}"
fi

echo "Importing IAM resources" >&2
safe_import "aws_iam_role.collector_role" "${COLLECTOR_ROLE_NAME}" "collector IAM role ${COLLECTOR_ROLE_NAME}"
safe_import "aws_iam_instance_profile.collector_profile" "${COLLECTOR_INSTANCE_PROFILE_NAME}" "collector instance profile ${COLLECTOR_INSTANCE_PROFILE_NAME}"
safe_import "aws_iam_policy.msk_control_plane" "${CONTROL_POLICY_ARN}" "MSK control plane policy ${MSK_CONTROL_POLICY_NAME}"
safe_import "aws_iam_policy.producer" "${PRODUCER_POLICY_ARN}" "producer policy ${PRODUCER_POLICY_NAME}"
safe_import "aws_iam_policy.consumer" "${CONSUMER_POLICY_ARN}" "consumer policy ${CONSUMER_POLICY_NAME}"
safe_import "aws_iam_role_policy_attachment.collector_control_attach" "${COLLECTOR_ROLE_NAME}/${CONTROL_POLICY_ARN}" "collector role to control plane policy attachment"
safe_import "aws_iam_role_policy_attachment.collector_producer_attach" "${COLLECTOR_ROLE_NAME}/${PRODUCER_POLICY_ARN}" "collector role to producer policy attachment"

if [ "${#missing_resources[@]}" -gt 0 ]; then
  echo "One or more resources could not be imported. Skipping terraform refresh/plan." >&2
  printf '  - %s\n' "${missing_resources[@]}" >&2
  exit 0
fi

echo "Refreshing state to verify imports" >&2
terraform apply -refresh-only -input=false -auto-approve

terraform plan -input=false

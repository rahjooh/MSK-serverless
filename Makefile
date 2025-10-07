SHELL := /bin/bash
MAKEFLAGS += --warn-undefined-variables
.ONESHELL:
.DEFAULT_GOAL := help

TF ?= terraform
TF_PLAN ?= tfplan.out
TF_VAR_FILE ?= terraform.tfvars

PLAN_ARGS ?=
APPLY_ARGS ?=
DESTROY_ARGS ?=
REFRESH_ARGS ?=
IMPORT_ARGS ?=
INIT_ARGS ?=

export AWS_REGION ?= ap-south-1
export MSK_CLUSTER_NAME ?= msk_crypto-stream
export VPC_ID ?= vpc-088763652e22bcc79
export TF_IN_AUTOMATION = 1
export TF_INPUT = 0

.PHONY: help init fmt validate plan apply plan-destroy destroy import-msk import-msk-auto import-support-resources refresh-state state-pull clean import force-destroy rebuild-tfstate

help: ## Show available targets
	@grep -E '^[a-zA-Z0-9_.-]+:.*##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*##"} {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

init: ## Initialize Terraform backend and providers
	$(TF) init $(INIT_ARGS)

fmt: ## Format Terraform configuration
	$(TF) fmt -recursive

validate: init ## Validate configuration
	$(TF) validate

plan: init validate ## Generate and store execution plan
	$(TF) plan -out=$(TF_PLAN) $(PLAN_ARGS)

apply: init ## Apply configuration (uses stored plan when present)
	if [ -f "$(TF_PLAN)" ]; then \
		$(TF) apply $(APPLY_ARGS) "$(TF_PLAN)"; \
	else \
		$(TF) apply $(APPLY_ARGS); \
	fi

plan-destroy: init ## Create destroy plan without applying it
	$(TF) plan -destroy $(PLAN_ARGS)

destroy: init ## Destroy managed infrastructure
	$(TF) destroy $(DESTROY_ARGS)

import-msk: init ## Import existing MSK cluster into state (requires MSK_CLUSTER_ARN)
	@: $${MSK_CLUSTER_ARN:?Set MSK_CLUSTER_ARN to the MSK cluster ARN}
	$(TF) import $(IMPORT_ARGS) aws_msk_serverless_cluster.this "$${MSK_CLUSTER_ARN}"

import-msk-auto: init ## Discover MSK ARN via AWS CLI and import (requires AWS_REGION and MSK_CLUSTER_NAME)
	@: $${MSK_CLUSTER_NAME:?Set MSK_CLUSTER_NAME to the MSK cluster name}
	@: $${AWS_REGION:?Set AWS_REGION to the AWS region for the cluster}
	MSK_CLUSTER_ARN=$$(aws kafka list-clusters-v2 --region "$${AWS_REGION}" --cluster-name-filter "$${MSK_CLUSTER_NAME}" --query 'ClusterInfoList[0].ClusterArn' --output text)
	if [ "$$MSK_CLUSTER_ARN" = "None" ] || [ -z "$$MSK_CLUSTER_ARN" ]; then \
	  echo "MSK cluster '$${MSK_CLUSTER_NAME}' not found in region $${AWS_REGION}"; exit 1; \
	fi
	$(TF) import $(IMPORT_ARGS) aws_msk_serverless_cluster.this "$$MSK_CLUSTER_ARN"


import-support-resources: init ## Import supporting resources (uses AWS_REGION/MSK_CLUSTER_NAME/VPC_ID defaults; override via env)
	@: $${AWS_REGION:?Set AWS_REGION to the AWS region for the resources}
	@: $${VPC_ID:?Set VPC_ID to the VPC containing the security groups}
	COLLECTOR_SG_NAME=$${COLLECTOR_SG_NAME:-msk_collectors}
	CONSUMER_SG_NAME=$${CONSUMER_SG_NAME:-msk_consumers}
	BROKER_SG_NAME=$${BROKER_SG_NAME:-$${MSK_CLUSTER_NAME:-msk_crypto-stream}_brokers}
	LOG_GROUP_NAME=$${LOG_GROUP_NAME:-$${MSK_CLUSTER_NAME:-msk_crypto-stream}_broker}
	ACCOUNT_ID=$${AWS_ACCOUNT_ID:-$$(aws sts get-caller-identity --query Account --output text)}
	COLLECTOR_SG_ID=$$(aws ec2 describe-security-groups --region "$${AWS_REGION}" --filters Name=vpc-id,Values="$${VPC_ID}" Name=group-name,Values="$$COLLECTOR_SG_NAME" --query "SecurityGroups[0].GroupId" --output text)
	if [ "$$COLLECTOR_SG_ID" = "None" ] || [ -z "$$COLLECTOR_SG_ID" ]; then \
	  echo "Collector security group '$$COLLECTOR_SG_NAME' not found"; exit 1; \
	fi
	CONSUMER_SG_ID=$$(aws ec2 describe-security-groups --region "$${AWS_REGION}" --filters Name=vpc-id,Values="$${VPC_ID}" Name=group-name,Values="$$CONSUMER_SG_NAME" --query "SecurityGroups[0].GroupId" --output text)
	if [ "$$CONSUMER_SG_ID" = "None" ] || [ -z "$$CONSUMER_SG_ID" ]; then \
	  echo "Consumer security group '$$CONSUMER_SG_NAME' not found"; exit 1; \
	fi
	BROKER_SG_ID=$$(aws ec2 describe-security-groups --region "$${AWS_REGION}" --filters Name=vpc-id,Values="$${VPC_ID}" Name=group-name,Values="$$BROKER_SG_NAME" --query "SecurityGroups[0].GroupId" --output text)
	if [ "$$BROKER_SG_ID" = "None" ] || [ -z "$$BROKER_SG_ID" ]; then \
	  echo "Broker security group '$$BROKER_SG_NAME' not found"; exit 1; \
	fi
	EGRESS_RULE_ID=$$(aws ec2 describe-security-group-rules --region "$${AWS_REGION}" --filters Name=group-id,Values="$$BROKER_SG_ID" Name=description,Values="Broker outbound" --query "SecurityGroupRules[0].SecurityGroupRuleId" --output text)
	if [ "$$EGRESS_RULE_ID" = "None" ] || [ -z "$$EGRESS_RULE_ID" ]; then \
	  echo "Broker egress rule not found"; exit 1; \
	fi
	COLLECTOR_RULE_ID=$$(aws ec2 describe-security-group-rules --region "$${AWS_REGION}" --filters Name=group-id,Values="$$BROKER_SG_ID" Name=description,Values="Collector-to-broker SASL/IAM TLS within VPC" --query "SecurityGroupRules[0].SecurityGroupRuleId" --output text)
	if [ "$$COLLECTOR_RULE_ID" = "None" ] || [ -z "$$COLLECTOR_RULE_ID" ]; then \
	  echo "Broker ingress rule for collectors not found"; exit 1; \
	fi
	CONSUMER_RULE_ID=$$(aws ec2 describe-security-group-rules --region "$${AWS_REGION}" --filters Name=group-id,Values="$$BROKER_SG_ID" Name=description,Values="Consumer-to-broker SASL/IAM TLS within VPC" --query "SecurityGroupRules[0].SecurityGroupRuleId" --output text)
	if [ "$$CONSUMER_RULE_ID" = "None" ] || [ -z "$$CONSUMER_RULE_ID" ]; then \
	  echo "Broker ingress rule for consumers not found"; exit 1; \
	fi
	$(TF) import $(IMPORT_ARGS) aws_cloudwatch_log_group.msk_broker "$$LOG_GROUP_NAME"
	$(TF) import $(IMPORT_ARGS) aws_security_group.collector "$$COLLECTOR_SG_ID"
	$(TF) import $(IMPORT_ARGS) aws_security_group.consumers "$$CONSUMER_SG_ID"
	$(TF) import $(IMPORT_ARGS) aws_security_group.msk_brokers "$$BROKER_SG_ID"
	$(TF) import $(IMPORT_ARGS) aws_vpc_security_group_egress_rule.msk_all_egress "$$EGRESS_RULE_ID"
	$(TF) import $(IMPORT_ARGS) aws_vpc_security_group_ingress_rule.msk_iam_9098_from_collector "$$COLLECTOR_RULE_ID"
	$(TF) import $(IMPORT_ARGS) aws_vpc_security_group_ingress_rule.msk_iam_9098_from_consumers "$$CONSUMER_RULE_ID"
	ROLE_NAME=$${MSK_CLUSTER_NAME:-msk_crypto-stream}_collector
	$(TF) import $(IMPORT_ARGS) aws_iam_role.collector_role "$$ROLE_NAME"
	$(TF) import $(IMPORT_ARGS) aws_iam_instance_profile.collector_profile "$$ROLE_NAME"
	$(TF) import $(IMPORT_ARGS) aws_iam_policy.msk_control_plane "arn:aws:iam::$$ACCOUNT_ID:policy/$${MSK_CLUSTER_NAME:-msk_crypto-stream}_msk_control"
	$(TF) import $(IMPORT_ARGS) aws_iam_policy.producer "arn:aws:iam::$$ACCOUNT_ID:policy/$${MSK_CLUSTER_NAME:-msk_crypto-stream}_producer"
	$(TF) import $(IMPORT_ARGS) aws_iam_policy.consumer "arn:aws:iam::$$ACCOUNT_ID:policy/$${MSK_CLUSTER_NAME:-msk_crypto-stream}_consumer"
	$(TF) import $(IMPORT_ARGS) aws_iam_role_policy_attachment.collector_control_attach "$$ROLE_NAME/arn:aws:iam::$$ACCOUNT_ID:policy/$${MSK_CLUSTER_NAME:-msk_crypto-stream}_msk_control"
	$(TF) import $(IMPORT_ARGS) aws_iam_role_policy_attachment.collector_producer_attach "$$ROLE_NAME/arn:aws:iam::$$ACCOUNT_ID:policy/$${MSK_CLUSTER_NAME:-msk_crypto-stream}_producer"
refresh-state: init ## Refresh state to match real infrastructure
	$(TF) apply -refresh-only -auto-approve $(REFRESH_ARGS)

state-pull: init ## Pull current state to terraform.tfstate
	$(TF) state pull > terraform.tfstate

clean: ## Remove cached plan artifact
	rm -f "$(TF_PLAN)"

force-destroy: ## Force delete MSK stack resources directly via AWS CLI (ignores Terraform state)
	@set -euo pipefail; \
	 echo "[force-destroy] Using AWS_REGION=$${AWS_REGION}, MSK_CLUSTER_NAME=$${MSK_CLUSTER_NAME}, VPC_ID=$${VPC_ID}"; \
	 ACCOUNT_ID=$${AWS_ACCOUNT_ID:-$$(aws sts get-caller-identity --query Account --output text)}; \
	 ROLE_NAME=$${MSK_CLUSTER_NAME}_collector; \
	 INSTANCE_PROFILE_NAME=$$ROLE_NAME; \
	 CONTROL_POLICY_ARN=arn:aws:iam::$$ACCOUNT_ID:policy/$${MSK_CLUSTER_NAME}_msk_control; \
	 PRODUCER_POLICY_ARN=arn:aws:iam::$$ACCOUNT_ID:policy/$${MSK_CLUSTER_NAME}_producer; \
	 CONSUMER_POLICY_ARN=arn:aws:iam::$$ACCOUNT_ID:policy/$${MSK_CLUSTER_NAME}_consumer; \
	 LOG_GROUP_NAME=$${LOG_GROUP_NAME:-$${MSK_CLUSTER_NAME}_broker}; \
	 COLLECTOR_SG_NAME=$${COLLECTOR_SG_NAME:-msk_collectors}; \
	 CONSUMER_SG_NAME=$${CONSUMER_SG_NAME:-msk_consumers}; \
	 BROKER_SG_NAME=$${BROKER_SG_NAME:-$${MSK_CLUSTER_NAME}_brokers}; \
	 echo "[force-destroy] Resolving resource identifiers"; \
	 CLUSTER_ARN=$$(aws kafka list-clusters-v2 --region "$${AWS_REGION}" --cluster-name-filter "$${MSK_CLUSTER_NAME}" --query 'ClusterInfoList[0].ClusterArn' --output text 2>/dev/null || true); \
	 COLLECTOR_SG_ID=$$(aws ec2 describe-security-groups --region "$${AWS_REGION}" --filters Name=vpc-id,Values="$${VPC_ID}" Name=group-name,Values="$$COLLECTOR_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true); \
	 CONSUMER_SG_ID=$$(aws ec2 describe-security-groups --region "$${AWS_REGION}" --filters Name=vpc-id,Values="$${VPC_ID}" Name=group-name,Values="$$CONSUMER_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true); \
	 BROKER_SG_ID=$$(aws ec2 describe-security-groups --region "$${AWS_REGION}" --filters Name=vpc-id,Values="$${VPC_ID}" Name=group-name,Values="$$BROKER_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true); \
	 if [ "$$CLUSTER_ARN" != "None" ] && [ -n "$$CLUSTER_ARN" ]; then \
	   echo "[force-destroy] Deleting MSK cluster $$CLUSTER_ARN"; \
	   aws kafka delete-cluster --region "$${AWS_REGION}" --cluster-arn "$${CLUSTER_ARN}" || true; \
	 else \
	   echo "[force-destroy] MSK cluster not found"; \
	 fi; \
	 if aws logs describe-log-groups --region "$${AWS_REGION}" --log-group-name-prefix "$${LOG_GROUP_NAME}" --query 'logGroups[?logGroupName==`'"$$LOG_GROUP_NAME"'`].logGroupName' --output text 2>/dev/null | grep -q "$${LOG_GROUP_NAME}"; then \
	   echo "[force-destroy] Deleting log group $$LOG_GROUP_NAME"; \
	   aws logs delete-log-group --region "$${AWS_REGION}" --log-group-name "$${LOG_GROUP_NAME}" || true; \
	 else \
	   echo "[force-destroy] Log group not found"; \
	 fi; \
	 if [ "$$BROKER_SG_ID" != "None" ] && [ -n "$$BROKER_SG_ID" ]; then \
	   echo "[force-destroy] Revoking broker security group rules for $$BROKER_SG_ID"; \
	   INGRESS_RULE_IDS=$$(aws ec2 describe-security-group-rules --region "$${AWS_REGION}" --filters Name=group-id,Values="$${BROKER_SG_ID}" Name=is-egress,Values=false --query 'SecurityGroupRules[].SecurityGroupRuleId' --output text 2>/dev/null || true); \
	   for RID in $$INGRESS_RULE_IDS; do [ "$$RID" = "None" ] && continue; [ -z "$$RID" ] && continue; aws ec2 revoke-security-group-ingress --region "$${AWS_REGION}" --group-id "$${BROKER_SG_ID}" --security-group-rule-ids "$$RID" >/dev/null 2>&1 || true; done; \
	   EGRESS_RULE_IDS=$$(aws ec2 describe-security-group-rules --region "$${AWS_REGION}" --filters Name=group-id,Values="$${BROKER_SG_ID}" Name=is-egress,Values=true --query 'SecurityGroupRules[].SecurityGroupRuleId' --output text 2>/dev/null || true); \
	   for RID in $$EGRESS_RULE_IDS; do [ "$$RID" = "None" ] && continue; [ -z "$$RID" ] && continue; aws ec2 revoke-security-group-egress --region "$${AWS_REGION}" --group-id "$${BROKER_SG_ID}" --security-group-rule-ids "$$RID" >/dev/null 2>&1 || true; done; \
	   echo "[force-destroy] Deleting broker security group $$BROKER_SG_NAME ($$BROKER_SG_ID)"; \
	   aws ec2 delete-security-group --region "$${AWS_REGION}" --group-id "$${BROKER_SG_ID}" || true; \
	 else \
	   echo "[force-destroy] Broker security group not found"; \
	 fi; \
	 if [ "$$COLLECTOR_SG_ID" != "None" ] && [ -n "$$COLLECTOR_SG_ID" ]; then \
	   echo "[force-destroy] Deleting collector security group $$COLLECTOR_SG_NAME ($$COLLECTOR_SG_ID)"; \
	   aws ec2 delete-security-group --region "$${AWS_REGION}" --group-id "$${COLLECTOR_SG_ID}" || true; \
	 else \
	   echo "[force-destroy] Collector security group not found"; \
	 fi; \
	 if [ "$$CONSUMER_SG_ID" != "None" ] && [ -n "$$CONSUMER_SG_ID" ]; then \
	   echo "[force-destroy] Deleting consumer security group $$CONSUMER_SG_NAME ($$CONSUMER_SG_ID)"; \
	   aws ec2 delete-security-group --region "$${AWS_REGION}" --group-id "$${CONSUMER_SG_ID}" || true; \
	 else \
	   echo "[force-destroy] Consumer security group not found"; \
	 fi; \
	 if aws iam get-role --role-name "$${ROLE_NAME}" >/dev/null 2>&1; then \
	   echo "[force-destroy] Detaching IAM policies from role $$ROLE_NAME"; \
	   aws iam detach-role-policy --role-name "$${ROLE_NAME}" --policy-arn "$$CONTROL_POLICY_ARN" >/dev/null 2>&1 || true; \
	   aws iam detach-role-policy --role-name "$${ROLE_NAME}" --policy-arn "$$PRODUCER_POLICY_ARN" >/dev/null 2>&1 || true; \
	   aws iam detach-role-policy --role-name "$${ROLE_NAME}" --policy-arn "$$CONSUMER_POLICY_ARN" >/dev/null 2>&1 || true; \
	 else \
	   echo "[force-destroy] IAM role $$ROLE_NAME not found"; \
	 fi; \
	 if aws iam get-instance-profile --instance-profile-name "$${INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then \
	   echo "[force-destroy] Removing role from instance profile $$INSTANCE_PROFILE_NAME"; \
	   aws iam remove-role-from-instance-profile --instance-profile-name "$${INSTANCE_PROFILE_NAME}" --role-name "$${ROLE_NAME}" >/dev/null 2>&1 || true; \
	   aws iam delete-instance-profile --instance-profile-name "$${INSTANCE_PROFILE_NAME}" >/dev/null 2>&1 || true; \
	 else \
	   echo "[force-destroy] Instance profile $$INSTANCE_PROFILE_NAME not found"; \
	 fi; \
	 if aws iam get-role --role-name "$${ROLE_NAME}" >/dev/null 2>&1; then \
	   echo "[force-destroy] Deleting IAM role $$ROLE_NAME"; \
	   aws iam delete-role --role-name "$${ROLE_NAME}" >/dev/null 2>&1 || true; \
	 fi; \
	 if aws iam get-policy --policy-arn "$$CONTROL_POLICY_ARN" >/dev/null 2>&1; then \
	   echo "[force-destroy] Deleting policy $$CONTROL_POLICY_ARN"; \
	   aws iam delete-policy --policy-arn "$$CONTROL_POLICY_ARN" >/dev/null 2>&1 || true; \
	 fi; \
	 if aws iam get-policy --policy-arn "$$PRODUCER_POLICY_ARN" >/dev/null 2>&1; then \
	   echo "[force-destroy] Deleting policy $$PRODUCER_POLICY_ARN"; \
	   aws iam delete-policy --policy-arn "$$PRODUCER_POLICY_ARN" >/dev/null 2>&1 || true; \
	 fi; \
	 if aws iam get-policy --policy-arn "$$CONSUMER_POLICY_ARN" >/dev/null 2>&1; then \
	   echo "[force-destroy] Deleting policy $$CONSUMER_POLICY_ARN"; \
	   aws iam delete-policy --policy-arn "$$CONSUMER_POLICY_ARN" >/dev/null 2>&1 || true; \
	 fi; \
	 rm -f resources.json; \
	 echo "[force-destroy] Completed best-effort cleanup"
import: import-msk-auto import-support-resources ## Import MSK cluster plus supporting resources (defaults set in Makefile)
	@echo "Imports complete."


rebuild-tfstate: ## Rebuild remote Terraform state by importing existing AWS resources
	./scripts/rebuild-tfstate.sh
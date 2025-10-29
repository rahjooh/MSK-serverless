variable "region" {
  type = string
}

variable "assume_role_arn" {
  description = "Optional role ARN that Terraform should assume before managing resources. Leave null to rely on the caller's credentials/session."
  type        = string
  default     = null
}

variable "pb_arn" {
  description = "Permissions boundary ARN required for IAM roles."
  type        = string
  default     = null
}

variable "access_scope" {
  description = "Access scope tag value required by organizational ABAC policies."
  type        = string
  default     = "Hadi"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string) 
}

variable "cluster_name" {
  type    = string
  default = null
}

variable "log_retention_days" {
  type    = number
  default = 5
}

variable "log_kms_key_arn" {
  type    = string
  default = null
}

# IAM scoping for Kafka resources
variable "producer_topic_prefixes" {
  type    = list(string)
  default = ["exchg."]
}

variable "consumer_topic_prefixes" {
  type    = list(string)
  default = ["exchg."]
}

variable "consumer_group_names" {
  type    = list(string)
  default = ["crypto-readers"]
}

# Collector SG settings (the SG we create for EC2 collectors)
variable "collector_sg_name" {
  type    = string
  default = null
}

variable "collector_sg_description" {
  type    = string
  default = "EC2 collectors for MSK"
}

variable "consumer_sg_name" {
  type    = string
  default = null
}

variable "consumer_sg_description" {
  type    = string
  default = "EC2 consumers for MSK"
}

variable "collector_sg_egress_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"] # allows NAT/Internet egress for collectors to reach exchanges
}

variable "tags" {
  type    = map(string)
  default = {}
}

# Existing infrastructure reuse (set these to avoid creating duplicates)
variable "existing_broker_log_group_name" {
  description = "Name of an existing CloudWatch Log Group for broker logs. When set, the module will reuse it instead of creating a new one."
  type        = string
  default     = null
}

variable "existing_collector_security_group_id" {
  description = "ID of an existing security group for EC2 collectors. When set, creation of a new collector security group is skipped."
  type        = string
  default     = null
}

variable "existing_consumer_security_group_id" {
  description = "ID of an existing security group for MSK consumers. When set, creation of a new consumer security group is skipped."
  type        = string
  default     = null
}

variable "existing_msk_broker_security_group_id" {
  description = "ID of an existing security group attached to MSK brokers. When set, creation of a new broker security group is skipped."
  type        = string
  default     = null
}

variable "existing_collector_role_name" {
  description = "Name of an existing IAM role for EC2 collectors. When set, the module reuses the role instead of creating a new one."
  type        = string
  default     = null
}

variable "existing_collector_instance_profile_name" {
  description = "Name of an existing IAM instance profile for EC2 collectors. When set, the module reuses it instead of creating a new one."
  type        = string
  default     = null
}

variable "existing_msk_control_policy_arn" {
  description = "ARN of an existing IAM policy that grants MSK control-plane permissions. When set, the module reuses the policy instead of creating a new one."
  type        = string
  default     = null
}

variable "existing_producer_policy_arn" {
  description = "ARN of an existing IAM policy that grants producer permissions. When set, the module reuses the policy instead of creating a new one."
  type        = string
  default     = null
}

variable "existing_consumer_policy_arn" {
  description = "ARN of an existing IAM policy that grants consumer permissions. When set, the module reuses the policy instead of creating a new one."
  type        = string
  default     = null
}
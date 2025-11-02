# MSK Serverless for Crypto Data Platform (Terraform)

Provision an **Amazon MSK Serverless** cluster (Kafka) with **IAM authentication on :9098**, **broker logs to CloudWatch Logs**, and **least-privilege IAM** policies for **EC2 producers (collectors)** and **consumer teams**—all inside a single VPC/Region.

This stack is designed for **high-frequency, small messages** (e.g., order book deltas, trades) produced by EC2 collectors and consumed by multiple internal teams.

---

## Table of Contents
- [Architecture](#architecture)
- [What this creates](#what-this-creates)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
  - [Variables](#variables)
  - [Example `example.tfvars`](#example-exampletfvars)
- [How to deploy](#how-to-deploy)
- [CI/CD (GitHub Actions)](#cicd-github-actions)
- [How to use](#how-to-use)
  - [Attach role/SG to EC2 collectors](#attach-rolesg-to-ec2-collectors)
  - [Producer client settings](#producer-client-settings)
  - [Consumers](#consumers)
  - [Creating topics](#creating-topics)
- [Operations](#operations)
  - [Monitoring & logs](#monitoring--logs)
  - [Scaling & quotas](#scaling--quotas)
  - [Cost notes](#cost-notes)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Extending](#extending)
- [Destroy](#destroy)
- [FAQ](#faq)

---

## Architecture

```
[EC2 Collectors] --IAM SASL/TLS:9098--> [MSK Serverless Cluster]
        |                                         |
        |                                 Broker logs -> CloudWatch Logs
        |                                         |
       VPC (same region) with SG rules that allow client SG -> broker SG on 9098
```

- **Producers (EC2 collectors)** live in the same VPC/Region and authenticate to Kafka using **IAM**.
- **Consumers** (other teams) get a reusable **consumer policy** they can attach to their roles.
- **Broker logs** are shipped to **CloudWatch Logs** for debugging.

---

## What this creates

- **MSK Serverless cluster**
  - IAM authentication enabled (SASL over TLS, port **9098**)
  - Broker logs to **CloudWatch Logs** (`/aws/msk/<cluster>/broker`)
- **Security Group** for the brokers
  - **Ingress**: allow **TCP 9098** from your **client SGs**
  - **Egress**: allow outbound to `0.0.0.0/0` (for control-plane/metrics)
- **IAM**
  - **Instance role & profile** for EC2 collectors (producers)
  - **Producer policy** with least-privilege topic access (by prefix)
  - **Control-plane policy** to fetch bootstrap brokers & describe the cluster
  - **Reusable consumer policy** for downstream teams (scoped to topic prefixes + group names)
- **Outputs**: cluster ARN/UUID, **bootstrap brokers (IAM)** string, broker SG ID, collector & consumer SG IDs, instance profile name, consumer policy ARN

---

## Repository layout

```
.
├── versions.tf          # Terraform & AWS provider constraints (>= 5.70)
├── provider.tf          # AWS provider & default tags (role assumption)
├── naming.tf            # Loads naming.yml and exposes canonical names
├── naming.yml           # Source of truth for resource naming
├── variables.tf         # Input variables
├── main.tf              # MSK Serverless, SG rules, CloudWatch logs
├── iam.tf               # IAM roles/policies for producers & consumers
├── outputs.tf           # Useful outputs
└── example.tfvars       # Example configuration values (edit for your env)
```

---

## Prerequisites

- **Terraform** ≥ 1.6
- AWS provider **≥ 5.70** (required for MSK Serverless `logging_info`)
- An **existing VPC** with **2+ subnets** in different AZs (recommended: private subnets)
- AWS credentials with permissions to create MSK, CloudWatch Logs, IAM roles/policies, and SG rules
- Credentials capable of assuming the `MSK-Builder` role in `ap-south-1` (the provider now assumes this role automatically)

> If you only have a default VPC, you can still use it for development. For production, use a dedicated VPC with private subnets and NAT egress for EC2 collectors to reach exchanges.

---

## Configuration

### Variables

Key inputs you must set:

- `region`: AWS region (e.g., `eu-west-1`)
- `vpc_id`: VPC where MSK will live
- `subnet_ids`: **2+** subnet IDs across different AZs (prefer private)
- `cluster_name`: Optional override for the cluster name (defaults to `naming.yml`)
- `producer_topic_prefixes`: Allowed topic name prefixes for producers (e.g., `["exchg.", "trades."]`)
- `consumer_topic_prefixes`: Allowed topic name prefixes for consumers (e.g., `["exchg."]`)
- `consumer_group_names`: Allowed consumer group names (exact match, e.g., `["team-quant"]`)
- `log_retention_days`: CloudWatch retention for broker logs (default `14`)
- `log_kms_key_arn`: Optional KMS key for log encryption
- `tags`: Map of default tags for all resources
- `access_scope`: ABAC tag value required by your organization (default `team-x`)
- `pb_arn`: IAM permissions boundary ARN required for roles (default points to `MSK-Permission-Boundary`)
- `existing_*`: Optional overrides to reuse pre-existing infrastructure (log group, security groups, IAM role/profile)

### Naming (YAML)

Resource names now live in [`naming.yml`](./naming.yml). Terraform loads the file via `yamldecode` (see `naming.tf`) and uses the `name` field for the MSK cluster, security groups, IAM resources, and the broker log group. Each entry also carries a short `description` plus an AWS Console `console_url` so teammates can jump directly to the resource. Override any entry by editing the YAML, or by supplying a variable (for example, `-var cluster_name=...`) when you need a one-off change.

### Example `example.tfvars`

```hcl
region     = "ap-south-1"
vpc_id     = "vpc-0abc1234"
subnet_ids = ["subnet-0aaa...", "subnet-0bbb..."]

producer_topic_prefixes = ["exchg.", "trades."]
consumer_topic_prefixes = ["exchg."]
consumer_group_names    = ["team-quant", "team-research"]

tags = {
  Project = "CryptoData"
  Owner   = "Hadi"
  Env     = "prod"
}
```

---

## How to deploy

```bash
terraform init -upgrade \
  -backend-config="bucket=<your-state-bucket>" \
  -backend-config="key=<your/prefix>/terraform.tfstate" \
  -backend-config="region=<bucket-region>"
terraform fmt -recursive
terraform validate
terraform plan -var-file=example.tfvars
terraform apply -var-file=example.tfvars
```

> **Remote state**: Terraform now uses an encrypted S3 backend. Supply your own bucket, prefix, and region via
> `terraform init -backend-config=...` (as shown above). The repository's `.gitignore` excludes local `terraform.tfstate`
> files so state is only stored in S3 (enable bucket versioning to keep history/backups). Use `terraform state pull` when you
> need a local copy for inspection.

### Assuming the `MSK-Builder` role

By default the provider uses whatever AWS identity is active when you run Terraform. If you need Terraform to assume `arn:aws:iam::61..:role/MSK-Builder`, set `assume_role_arn` in your `.tfvars` (or via CLI variables). Otherwise leave it `null` and authenticate ahead of time (for example with `AWS_PROFILE=msk-builder`).

One convenient CLI profile that handles the MFA prompt and role chaining:

```ini
[profile msk-builder]
region = ap-south-1
role_arn = arn:aws:iam::64..:role/MSK-Builder
source_profile = hadi
```

Use the profile when running Terraform so STS obtains session credentials before the provider starts:

```bash
export AWS_PROFILE=msk-builder
aws sts get-caller-identity   # should show assumed-role/MSK-Builder/...
terraform plan -var-file=example.tfvars
terraform apply -var-file=example.tfvars
```

If you set `assume_role_arn`, make sure the base credentials have permission to assume that role and that the role policy allows being assumed by your principal.

**Outputs** to note:
- `bootstrap_brokers_sasl_iam` → the comma-separated broker endpoints for clients (TLS **:9098**)
- `collector_instance_profile_name` → attach to EC2 collectors
- `consumer_policy_arn` → attach to consumer roles
- `msk_broker_security_group_id` → broker SG (ingress restricted to collector/consumer SGs)
- `collector_sg_id`, `consumer_sg_id` → attach to EC2 collectors and consumer workloads, respectively
- `msk_cluster_arn`, `msk_cluster_uuid` → useful for auditing or manual IAM scoping

---

## CI/CD (GitHub Actions)

> Mirror these recommendations in whatever CI/CD platform you use. They assume GitHub-hosted runners with AWS federation via OIDC.

1. **Pin toolchain versions**
   - Install Terraform ≥ 1.6 and the AWS provider ≥ 5.70/5.100 explicitly so workflow runs stay compatible with this configuration.
2. **Run the same commands as local deployment**
   - Execute `terraform init -upgrade`, `terraform fmt -recursive`, `terraform validate`, and `terraform plan` in CI to catch syntax and drift issues before any apply.
   - Upload the generated plan as an artifact for review.
3. **Require human approval before apply**
   - Keep `terraform apply` in a separate job that consumes the reviewed plan artifact and is gated by manual approval or protected environments.
4. **Rely on short-lived credentials**
   - Configure GitHub’s OIDC provider to assume the existing `MSK-Builder` role instead of checking in long-lived AWS access keys.
   - If environments use different roles, surface a variable such as `assume_role_arn` and feed it from environment or repository secrets.
5. **Securely pass variables and secrets**
   - Store environment-specific values in the `TERRAFORM_TFVARS` secret using the same HCL syntax that Terraform expects in a `.tfvars` file. Optional `# workflow.<key> = <value>` comments inside that payload let CI read GitHub-only settings (backend bucket, assume-role ARN, summary destinations) without introducing extra repository secrets.
6. **Centralize Terraform state**
   - Point Terraform at a remote backend (e.g., S3 with DynamoDB locking) so concurrent runs do not clash on local state.
   - Use separate backends or workspaces per environment and restrict who can trigger production applies.
7. **Surface plan feedback**
   - Have the plan job comment on pull requests and schedule periodic plan-only runs for drift detection so you can spot unintended changes without applying.

### Reference workflow in this repository

The `.github/workflows/terraform.yml` pipeline implements the guidance above with five dedicated jobs:

| Job | Purpose |
| --- | --- |
| `validate` | Runs `terraform fmt`, `terraform validate`, and captures a reusable plan artifact for reviewers. |
| `terraform-init` | Performs a standalone initialization check against the configured backend so remote state issues surface early. |
| `apply` | Gated behind manual `workflow_dispatch` and the protected `production` environment; consumes the reviewed plan to apply infrastructure changes. |
| `report` | Publishes `terraform output` values to the workflow summary after a successful apply so stakeholders can see new infrastructure details. |
| `destroy` | Provides an on-demand teardown path that requires the same approvals as apply. |

To feed environment-specific variables, store the exact contents of your `.tfvars` file in the encrypted `TERRAFORM_TFVARS` secret. The loader writes the payload to `ci.auto.tfvars` for Terraform and exports matching `TF_VAR_` environment variables for CLIs that prefer them. Because the payload is native HCL, you can copy it directly to `terraform.tfvars` for local runs.

Optional CI-only settings can be provided through comment directives that start with `# workflow.` or `// workflow.`. Supported directives include:

- `workflow.backend.bucket`, `workflow.backend.key`, `workflow.backend.region`, `workflow.backend.dynamodb_table`
- `workflow.summary.bucket`, `workflow.summary.key`
- `workflow.use_existing`

Example secret value:

```hcl
region          = "ap-south-1"
assume_role_arn = "arn:aws:iam::123456789012:role/MSK-Builder"

vpc_id     = "vpc-0abc123def4567890"
subnet_ids = [
  "subnet-0aaabbbbcccc11111",
  "subnet-0ddddeeeeffff22222",
]

producer_topic_prefixes = ["exchg.", "trades."]
consumer_topic_prefixes = ["exchg."]
consumer_group_names    = ["team-quant", "team-research"]

tags = {
  Project = "Data"
  Owner   = "Hadi"
  Env     = "prod"
}

log_retention_days = 3
log_kms_key_arn    = null

# workflow.backend.bucket = "terraform-state-bucket"
# workflow.backend.key    = "cluster/prod/terraform.tfstate"
# workflow.backend.region = "ap-south-1"
# workflow.summary.bucket = "msk-cluster-reports"
# workflow.summary.key    = "terraform/cluster/resources.json"
# workflow.use_existing   = true
```

Omit any directives you do not need. The loader gracefully falls back to repository defaults when optional settings (such as the summary location) are absent.


### Rebuilding state after corruption

If the remote Terraform state stored in S3 is ever lost or corrupted, trigger the on-demand workflow defined in [`rebuild-tfstate.yml`](.github/workflows/rebuild-tfstate.yml). The job calls [`scripts/rebuild-tfstate.sh`](./scripts/rebuild-tfstate.sh) which:

1. Initializes Terraform against the provided backend bucket/key (plus optional DynamoDB lock table).
2. Discovers the canonical resource names from `naming.yml` and any variable overrides provided via `TF_VAR_*` environment variables.
3. Uses the AWS CLI to look up the live MSK cluster, security groups, CloudWatch log group, and IAM artifacts that this stack manages.
4. Imports each resource into the backend state and performs a refresh-only apply followed by a plan for validation.

To run the workflow:

- Ensure the `assume_role_arn` variable inside `TERRAFORM_TFVARS` points to the AWS role that should import the stack (adjust the workflow if you require a different credential model).
- Provide the minimum required Terraform variables in that same payload—specifically `region`, `vpc_id`, and `subnet_ids`. Optional overrides such as custom names or tags can also live alongside those variables.
- From the Actions tab choose **Rebuild Terraform state**, supply the S3 bucket, object key, backend region, and (optionally) the DynamoDB table used for state locking, then start the run.

> The importer is idempotent: rerunning it simply reaffirms the existing mappings. Always review the terminal plan output before resuming regular Terraform changes to confirm no drift remains.

---

## How to use

### Attach role/SG to EC2 collectors

When launching your EC2 collectors:
- **Instance profile**: attach `collector_instance_profile_name`
- **Security Group**: attach the Terraform-managed SG from the `collector_sg_id` output
- Ensure instances have **egress to the internet** (NAT) to reach exchange WebSocket/REST APIs

### Producer client settings

General Kafka settings that work well for **small, frequent messages**:

- **Bootstrap**: use `bootstrap_brokers_sasl_iam` (TLS **:9098**)
- **Auth**: IAM SASL (per your client lib; e.g., `kafka-go` IAM mechanism, or Confluent clients’ AWS MSK IAM)
- `acks=all`
- **Idempotence**: **enabled** (no transactions with IAM; dedupe downstream if needed)
- `compression=zstd`
- `linger.ms=5..20` and reasonable batch bytes for better throughput

### Consumers

- Attach the **`consumer_policy_arn`** to the role used by consumer apps
- Place consumer workloads in the Terraform-managed `consumer_sg_id` (or allow their SG to ingress to the broker SG)
- Use the same `bootstrap_brokers_sasl_iam` and IAM SASL config
- Join **only** the consumer groups listed in `consumer_group_names` (policy-enforced)

### Creating topics

- The producer policy includes `kafka-cluster:CreateTopic` for the **configured prefixes**.
- Create topics explicitly (CLI/admin client) or allow your producer tooling to create them.
- **Naming convention** (suggested):  
  `exchg.<exchange>.<market>[.contract]::<datatype>::<symbol>`  
  e.g., `exchg.binance.spot::orderbook.delta::BTCUSDT`

> MSK often disables auto-topic-creation; creating topics explicitly is the safer path.

---

## Operations

### Monitoring & logs

- **Broker logs** → CloudWatch Logs group `/aws/msk/<cluster>/broker`
- **Cluster metrics** → CloudWatch (MessagesIn, BytesIn/Out, MaxOffsetLag).  
  When checking per-topic rates composed of many partitions, **SUM** across partitions to see totals.

### Scaling & quotas

- MSK Serverless handles capacity behind the scenes. You still plan **partitions** based on parallelism and ordering needs (e.g., 1 partition per symbol).
- Keep per-partition storage within service limits when using long retentions.
- If you hit partition/throughput ceilings, shard topics or split by symbol groups.

### Cost notes

- MSK Serverless: charged primarily by **GB in/out** and **partition-hours**. Even when no custom topics or data exist, Kafka’s internal topics (e.g., `__consumer_offsets`, MSK health canaries) still contribute dozens of partitions that accrue charges every hour the cluster runs.
  - Expect roughly **$0.70–$0.80 per hour** (region dependent) for the built-in partitions alone (~50 partitions × $0.015/partition-hour ≈ $14–$18/day).
  - Confirm in the AWS Billing console under the “MSK Serverless Partition Hours” line item.
  - Destroy the cluster (`terraform destroy`) when idle—there is no pause state for Serverless MSK.
- CloudWatch Logs: ingestion + retention
- EC2 instances & NAT egress for collectors

---

## Security

- **No public access**; all traffic is **in-VPC** over **TLS :9098**
- **SG ingress** scoped to known **client SGs** only
- **IAM**:
  - Producers: `Connect` + `WriteData(Idempotently)` on cluster, and `DescribeTopic/WriteData/CreateTopic` on **allowed topic prefixes**
  - Consumers: `Connect` + `DescribeTopic/ReadData` on **allowed topic prefixes**, and group management on **named groups**
- **Least privilege** by default; extend prefixes/groups as needed per team

---

## Troubleshooting

- **Terraform reports resources already exist**
  - Re-run Terraform with the matching `existing_*` variables set (for example `existing_broker_log_group_name`, `existing_msk_broker_security_group_id`, or `existing_collector_role_name`) so the module reuses the pre-existing resources instead of creating new ones.

- **Security groups remain after destroy**
  - When `existing_collector_security_group_id` or `existing_consumer_security_group_id` is populated, Terraform treats the security groups as external data sources and will not delete them during destroy.
  - If the state no longer tracks the security groups, import them using `scripts/rebuild-tfstate.sh` and then run `terraform destroy`, or delete them manually in the AWS console if they are managed outside of Terraform.

- **Invalid single-argument block** (HCL)
  - Don’t use single-line blocks with multiple attributes. Use multi-line syntax:
    ```hcl
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    ```

- **`cidr_block` not expected** on SG rule
  - Use `cidr_ipv4` with AWS provider v5:
    ```hcl
    cidr_ipv4 = "0.0.0.0/0"
    ```

- **`logging_info` not expected** on MSK Serverless
  - Ensure provider is **>= 5.70** (`terraform init -upgrade`), or remove the logging block.

- **Connection refused / timeout**
  - Verify the instance is using the `collector_sg_id` (or `consumer_sg_id`) output and that the broker SG shows **ingress 9098** from it.
  - Ensure route/NAT egress for EC2 collectors to reach exchanges (unrelated to Kafka path but needed for ingestion).

- **Authorization failed**
  - Producers/consumers must run with roles that have the **attached policies** from this stack.
  - Topic name must match an **allowed prefix**; consumer group must be one of `consumer_group_names`.

- **UnknownTopicOrPartition**
  - Create the topic explicitly or verify your producer created it and your consumer policy allows reading it.

---

## Extending

- **MSK Connect**: add managed sinks (S3, JDBC, OpenSearch) without changing your code.
- **Schema**: if you later need enforcement, add **AWS Glue Schema Registry** or Confluent Schema Registry.
- **Multi-VPC / Cross-account**: introduce **MSK multi-VPC private connectivity (PrivateLink)** and cluster/identity policies (not needed if everyone is in the same VPC).

---

## Destroy

```bash
terraform destroy -var-file=example.tfvars
```

> Destroy will remove the MSK cluster, IAM roles/policies, SG rules, and CloudWatch log group (logs may be retained if you changed the behavior). Make sure all consumers/producers have been stopped.

---

## FAQ

**Q: Which port do clients use?**  
A: **9098/TLS** for IAM SASL (use the `bootstrap_brokers_sasl_iam` output).

**Q: Do I need to manage broker instances?**  
A: No—this is **Serverless**. You still manage topics, partitions, and IAM.

**Q: Can I use Kafka transactions (EOS) with IAM?**  
A: No. IAM auth doesn’t support **WriteTxnMarkers**. Use **idempotent producers** + dedupe if you need strong delivery guarantees.

**Q: Where do I see broker logs?**
A: In **CloudWatch Logs** under `/aws/msk/<cluster>/broker`.

**Q: Why am I billed when no topics or data exist?**
A: MSK Serverless automatically provisions internal Kafka system topics with many partitions (e.g., `__consumer_offsets`, canary topics). Partition-hours are billable whether or not traffic flows, so the system partitions alone can total **~$14 per day**. Delete the cluster when idle to eliminate the charge.

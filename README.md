# LLM Router — Dynamic Model Selection on AWS

A production-grade LLM routing system built on **Amazon Bedrock AgentCore** that dynamically selects and switches between model providers based on task complexity, cost budgets, latency requirements, and quality thresholds.

## Architecture Overview

```
Client → API Gateway → AgentCore Gateway → Router Agent (AgentCore Runtime)
                                                    │
                                    ┌───────────────┼───────────────┐
                                    ▼               ▼               ▼
                              Bedrock Models   SageMaker EP    External APIs
                              (Nova, Claude,   (Fine-tuned)    (OpenAI, etc.)
                               Llama, Mistral)
```

The Router Agent classifies each request's complexity using a fast/cheap model (Nova Lite), then dispatches to the optimal model based on configurable policies. A feedback loop continuously adjusts model weights based on observed performance.

## Project Structure

```
├── architecture/           # Design document
├── terraform/              # Infrastructure as Code
│   ├── main.tf            # Provider config, locals
│   ├── variables.tf       # Input variables
│   ├── agentcore.tf       # AgentCore Runtime & Gateway
│   ├── cognito.tf         # Authentication (Cognito)
│   ├── dynamodb.tf        # Routing policies & metrics tables
│   ├── lambda.tf          # Lambda functions (tools)
│   ├── kinesis.tf         # Event streaming
│   ├── appconfig.tf       # Hot-swap feature flags
│   ├── api_gateway.tf     # Public API endpoint
│   ├── iam.tf             # IAM roles & policies
│   ├── secrets.tf         # External provider credentials
│   ├── observability.tf   # CloudWatch dashboard & alarms
│   └── outputs.tf         # Terraform outputs
├── agent/                  # Router agent container
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app.py             # Agent logic (Strands framework)
├── lambda/                 # Lambda function source
│   ├── complexity_classifier/
│   ├── model_invoker/
│   ├── feedback_collector/
│   ├── weight_adjuster/
│   └── api_proxy/
└── scripts/               # Deployment helpers
    ├── deploy.sh
    └── get-token.sh
```

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.14.0
- Docker (for building the agent container)
- Bedrock model access enabled for your account (Nova, Claude, etc.)

## Quick Start

### 1. Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 2. Deploy

```bash
# Full deployment (builds image + applies terraform)
./scripts/deploy.sh

# Or step by step:
cd terraform
terraform init
terraform plan
terraform apply
```

### 3. Create a Test User

```bash
aws cognito-idp admin-create-user \
  --user-pool-id $(terraform output -raw cognito_user_pool_id) \
  --username user@example.com \
  --user-attributes Name=email,Value=user@example.com \
  --temporary-password 'TempPass123!'
```

### 4. Get Token & Test

```bash
./scripts/get-token.sh

# Or manually:
curl -X POST "$(terraform output -raw chat_completions_url)" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Explain quantum computing"}],
    "routing": {"policy": "default"}
  }'
```

## API

The router exposes an **OpenAI-compatible** `/v1/chat/completions` endpoint with additional routing metadata:

### Request

```json
{
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Your question here"}
  ],
  "routing": {
    "policy": "default",
    "max_cost": 0.01,
    "prefer_provider": "bedrock"
  }
}
```

### Response

```json
{
  "id": "chatcmpl-abc123",
  "model": "anthropic.claude-sonnet-4-20250514-v1:0",
  "choices": [{
    "message": {"role": "assistant", "content": "..."},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 50, "completion_tokens": 200, "total_tokens": 250},
  "routing": {
    "complexity": "moderate",
    "model_selected": "anthropic.claude-sonnet-4-20250514-v1:0",
    "provider": "bedrock",
    "latency_ms": 1234,
    "escalated": false
  }
}
```

## Routing Policies

Policies are stored in DynamoDB and can be updated without redeployment:

| Policy | Cost Limit | Quality Floor | Strategy |
|--------|-----------|---------------|----------|
| `default` | $0.05/req | 0.8 | Complexity-based |
| `enterprise` | $0.50/req | 0.95 | Quality-maximized |
| `budget_conscious` | $0.005/req | 0.6 | Cost-optimized |

## Hot-Swap with AppConfig

Enable/disable models or shift traffic instantly via AppConfig feature flags — no deployment needed:

```bash
# Disable a model (e.g., during a cost spike)
# Update the feature flag in AppConfig console or via CLI
aws appconfig start-deployment ...
```

## Monitoring

- **CloudWatch Dashboard**: Pre-built dashboard showing requests/model, latency percentiles, cost per model, quality scores, and circuit breaker status
- **Alarms**: High error rate, latency spikes, cost thresholds, circuit breaker events
- **SNS Alerts**: Subscribe to get notified on routing issues

## Configuration

See `terraform/variables.tf` for all configurable options. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `enable_external_providers` | `false` | Route to OpenAI, etc. |
| `enable_sagemaker_endpoint` | `false` | Route to self-hosted models |
| `default_quality_threshold` | `0.8` | Minimum quality score |
| `router_agent_min_instances` | `2` | Warm instances for low latency |

## Cleanup

```bash
cd terraform
terraform destroy
```

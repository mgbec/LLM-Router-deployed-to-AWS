# LLM Router — Dynamic Model Selection on AWS

A production-grade LLM routing system built on **Amazon Bedrock AgentCore** that dynamically selects and switches between model providers based on task complexity, cost budgets, latency requirements, and quality thresholds. Designed with **ISO 42001** (AI Management Systems) compliance built in.

## Architecture Overview

```
Client → API Gateway → AgentCore Gateway → Router Agent (AgentCore Runtime)
                                                    │
                              ┌──────────────────────┼──────────────────────┐
                              ▼                      ▼                      ▼
                     Bedrock Guardrails     Data Classification      Kill Switch
                     (Content Safety)      (PII/Residency Check)    (AppConfig)
                              │                      │
                              ▼                      ▼
                    ┌─────────┼──────────────────────┼─────────┐
                    ▼         ▼                      ▼         ▼
              Bedrock Models   SageMaker EP    External APIs
              (Nova, Claude,   (Fine-tuned)    (OpenAI, etc.)
               Llama, Mistral)                 [PII blocked]
```

The Router Agent classifies each request's complexity using a fast/cheap model (Nova Lite), then dispatches to the optimal model based on configurable policies. A feedback loop continuously adjusts model weights based on observed performance.

## Project Structure

```
├── architecture/
│   ├── llm-router-architecture.md    # Full system design
│   └── iso-42001-gap-analysis.md     # ISO 42001 compliance analysis
├── terraform/
│   ├── main.tf                       # Provider config, locals
│   ├── variables.tf                  # Input variables
│   ├── agentcore.tf                  # AgentCore Runtime & Gateway
│   ├── cognito.tf                    # Authentication (Cognito)
│   ├── dynamodb.tf                   # Routing policies & metrics tables
│   ├── lambda.tf                     # Lambda functions (tools)
│   ├── kinesis.tf                    # Event streaming
│   ├── appconfig.tf                  # Hot-swap feature flags
│   ├── api_gateway.tf                # Public API endpoint
│   ├── iam.tf                        # IAM roles & policies
│   ├── secrets.tf                    # External provider credentials
│   ├── observability.tf              # CloudWatch dashboard & alarms
│   ├── xray_tracing.tf              # X-Ray cross-service trace correlation
│   ├── guardrails.tf                # Bedrock Guardrails (content + PII)
│   ├── human_oversight.tf           # Kill switch, concern reporting, overrides
│   ├── transparency.tf             # Routing explanations, audit log, model cards
│   ├── data_classification.tf      # Data sensitivity scanning, residency enforcement
│   ├── governance.tf               # AI Policy, Risk Register, Impact Assessment
│   └── outputs.tf                   # Terraform outputs
├── agent/                            # Router agent container
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app.py                        # Agent logic (Strands framework)
├── lambda/
│   ├── api_proxy/                    # Proxies API GW → AgentCore Runtime
│   ├── complexity_classifier/        # Classifies prompt complexity
│   ├── model_invoker/                # Invokes selected model
│   ├── feedback_collector/           # Records quality metrics
│   ├── weight_adjuster/              # Kinesis consumer, adjusts model weights
│   ├── data_classifier/              # Scans for PII, enforces data residency
│   ├── human_override/               # Kill switch, block/pin models, report concerns
│   └── transparency_api/             # Routing explanations, audit log, model info
└── scripts/
    ├── deploy.sh                     # Full build + push + apply
    └── get-token.sh                  # Get Cognito auth token for testing
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
# Full deployment (creates infra, builds image, pushes to ECR)
./scripts/deploy.sh

# Or step by step:
cd terraform
terraform init
terraform apply                    # Creates ECR repo + all infrastructure

# Then build and push the agent image:
ECR_REPO=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_REPO
docker build -t $ECR_REPO:latest ../agent
docker push $ECR_REPO:latest
```

Note: Terraform creates the ECR repository automatically. You don't need to provide an image URI upfront — just push your image after the first apply.

### 3. Create a Test User

```bash
aws cognito-idp admin-create-user \
  --region us-east-1 \
  --user-pool-id $(terraform output -raw cognito_user_pool_id) \
  --username testuser \
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

## API Endpoints

All endpoints except `/health` require JWT authentication via Cognito.

### Core

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/chat/completions` | Main routing endpoint (OpenAI-compatible) |
| `GET` | `/v1/routing/status` | Current model availability and circuit breaker state |
| `GET` | `/health` | Health check (unauthenticated) |

### Transparency (ISO 42001 A.8)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/v1/routing/explain/{requestId}` | Why a model was chosen for a request |
| `GET` | `/v1/audit/my-requests` | User's routing history (which models served them) |
| `GET` | `/v1/models/info` | Model cards — capabilities, limitations, data residency |

### Human Oversight (ISO 42001 A.9.5)

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/concerns/report` | Report problematic AI output for human review |
| `POST` | `/v1/admin/override` | Kill switch, block/pin models, require human review |

### Request/Response Format

**Request:**
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

**Response:**
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

**Response Headers (Transparency):**
```
X-AI-Model: anthropic.claude-sonnet-4-20250514-v1:0
X-AI-Provider: bedrock
X-AI-Routed: true
X-AI-Complexity: moderate
X-AI-Disclosure: Response generated by dynamically-selected AI model.
```

## Routing Policies & Strategies

**Policies** define constraints (the "what"):

| Policy | Cost Limit | Quality Floor | Strategy |
|--------|-----------|---------------|----------|
| `default` | $0.05/req | 0.8 | Complexity-based |
| `enterprise` | $0.50/req | 0.95 | Quality-maximized |
| `budget_conscious` | $0.005/req | 0.6 | Cost-optimized |

**Strategies** define the selection algorithm (the "how"):

| Strategy | Description |
|----------|-------------|
| `complexity_based` | Classify prompt difficulty → match to model tier |
| `cost_optimized` | Always pick cheapest model meeting quality floor |
| `latency_optimized` | Pick fastest-responding provider |
| `quality_maximized` | Always pick most capable model |
| `cascade` | Try cheap first, escalate if confidence is low |
| `round_robin` | Distribute for A/B testing |

Policies are stored in DynamoDB and can be updated without redeployment.

## ISO 42001 Compliance

Built-in components addressing ISO/IEC 42001:2023 (AI Management Systems):

| Component | Controls | What it does |
|-----------|----------|--------------|
| Bedrock Guardrails | A.9.4, A.7.5 | Content filtering, PII masking, topic blocking, prompt attack detection |
| Data Classification | A.7.5, A.7.6 | Scans for PII before external routing, enforces data residency, logs decisions |
| Human Oversight | A.9.5, A.3.3 | Kill switch, model override, concern reporting with SLA tracking |
| Transparency API | A.8.2–A.8.4 | Routing explanations, user audit log, model cards, mandatory disclosure headers |
| Governance Docs | A.2, A.5, A.6.2.9 | AI Policy, Risk Register, Impact Assessment, Acceptable Use Policy (versioned S3) |
| X-Ray Tracing | A.6.2.6 | Full cross-service trace correlation with sampling rules |

See `architecture/iso-42001-gap-analysis.md` for the full control mapping.

## Observability

- **X-Ray**: Cross-service distributed tracing with trace group, environment-aware sampling rules, and insights enabled
- **CloudWatch Dashboard**: 7 panels — requests/model, latency p50/p95/p99, cost/model, quality scores, escalations, circuit breakers, complexity distribution
- **Alarms**: Error rate, latency (p99 > 5s), cost spikes, circuit breaker opens, human review backlog
- **Audit Logs**: Routing audit (90-day), data flow log (90-day), human override log (90-day)
- **Kinesis**: Real-time routing event stream feeding the adaptive weight-adjustment Lambda

## Hot-Swap with AppConfig

Enable/disable models or shift traffic instantly — no deployment needed:

- **Routing config**: Toggle models, adjust traffic split percentages, configure cascade thresholds
- **Kill switch**: Halt the entire system, disable individual providers, or force human review for categories

## Configuration

Key settings in `terraform/variables.tf`:

| Variable | Default | Description |
|----------|---------|-------------|
| `router_agent_image_tag` | `latest` | Docker tag (ECR repo created automatically) |
| `enable_external_providers` | `false` | Route to OpenAI, etc. |
| `enable_sagemaker_endpoint` | `false` | Route to self-hosted models |
| `default_quality_threshold` | `0.8` | Minimum quality score |
| `router_agent_min_instances` | `2` | Warm instances for low latency |
| `network_mode` | `PUBLIC` | AgentCore network mode |
| `log_retention_days` | `30` | CloudWatch log retention |

## Cleanup

```bash
cd terraform
terraform destroy
```

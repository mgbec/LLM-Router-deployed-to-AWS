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
    ├── get-token.sh                  # Get Cognito auth token + quick test
    └── run-tests.sh                  # Comprehensive test suite (25 tests)
```

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.5.0 (tested with 1.13.1)
- AWS Provider 6.54.0+
- Docker with buildx and QEMU support (for ARM64 cross-compilation)
- Bedrock model access enabled for your account
- jq (for test scripts)

### One-Time Setup

**Enable Bedrock model access** — In the AWS Console, go to Bedrock → Model Access and enable:
- Amazon Nova Lite
- Amazon Nova Pro
- Anthropic Claude Sonnet 4
- Anthropic Claude Opus 4 (optional, for complex tier)

**Enable Docker ARM64 cross-compilation** (required on Intel/AMD machines):
```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

## Quick Start

### 1. Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 2. Deploy

```bash
# Full deployment (creates ECR, builds ARM64 image, pushes, deploys infra)
./scripts/deploy.sh
```

The deploy script runs in two phases:
1. Creates the ECR repository (Terraform targeted apply)
2. Builds and pushes the ARM64 Docker image
3. Applies all remaining infrastructure (AgentCore validates the image exists)

For step-by-step manual deployment:
```bash
cd terraform
terraform init
terraform apply -target=aws_ecr_repository.router_agent  # Phase 1: ECR

# Build and push ARM64 image
ECR_REPO=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $(echo $ECR_REPO | cut -d/ -f1)
docker build --platform linux/arm64 -t $ECR_REPO:latest ../agent
docker push $ECR_REPO:latest

terraform apply  # Phase 2: Everything else
```

### 3. Create a Test User

The Cognito pool uses email as an alias, so the username must NOT be an email address:

```bash
aws cognito-idp admin-create-user \
  --region us-east-1 \
  --user-pool-id $(cd terraform && terraform output -raw cognito_user_pool_id) \
  --username testuser \
  --user-attributes Name=email,Value=you@example.com \
  --temporary-password 'TempPass123!'
```

### 4. Get Token & Test

```bash
./scripts/get-token.sh
```

The script will:
1. Prompt for username and password
2. Handle the NEW_PASSWORD_REQUIRED challenge (first login)
3. Acquire an access token
4. Run a health check against the API
5. Send a test chat completion request and display the response

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

## Testing

### Quick Test

```bash
./scripts/get-token.sh
```

Authenticates and sends a single chat completion request to verify the system is working.

### Full Test Suite

```bash
./scripts/run-tests.sh
```

Runs ~25 tests across 10 categories:

| # | Category | What it validates |
|---|----------|-------------------|
| 1 | Health & Connectivity | Endpoints respond, auth enforcement works |
| 2 | Basic Routing | Simple prompts route successfully, return content |
| 3 | Complexity-Based Routing | Moderate/complex prompts get different treatment |
| 4 | Routing Policies | Default, budget-conscious, enterprise, cost overrides |
| 5 | Multi-Turn Conversation | System prompts, context retention across turns |
| 6 | Transparency API | Model info, user audit log, routing explanations |
| 7 | Human Oversight API | Concern reporting, admin override actions |
| 8 | Response Headers | X-AI-Model and X-AI-Routed disclosure headers |
| 9 | Error Handling | Empty messages, invalid policy, malformed JSON |
| 10 | Guardrails | Medical advice topic blocking |

To skip the login prompt on repeated runs, export the token:

```bash
export LLM_ROUTER_TOKEN="<your-access-token>"
./scripts/run-tests.sh
```

## Cleanup

```bash
cd terraform
terraform destroy
```

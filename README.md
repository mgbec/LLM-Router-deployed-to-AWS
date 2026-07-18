# LLM Router — Dynamic Model Selection on AWS

A production-grade LLM routing system built on **Amazon Bedrock AgentCore** that dynamically selects and switches between model providers based on task complexity, cost budgets, latency requirements, and quality thresholds. Designed with **ISO 42001** (AI Management Systems) compliance built in.

## Architecture Overview

```
Client → API Gateway → API Proxy Lambda
                            │
                  ┌─────────┼──────────────────────┐
                  │         │                      │
            [Simple/Mod]  [Complex auto-detect]   [Explicit async]
                  │         │                      │
                  ▼         ▼                      ▼
            Sync Path    202 Accepted          202 Accepted
                  │         │                      │
                  ▼         └──────────┬───────────┘
         AgentCore Runtime             ▼
              │               Async Processor Lambda (15 min)
              │                        │
              ▼                        ▼
     ┌────────────────┐        AgentCore Runtime
     │  Kill Switch   │               │
     │  (AppConfig)   │               │
     └────────┬───────┘               │
              ▼                        ▼
     ┌────────────────┐     ┌────────────────────┐
     │  Complexity    │     │  Model Invocation   │
     │  Classifier    │     │  (Opus for complex) │
     │  (Nova Lite)   │     └────────────────────┘
     └────────┬───────┘               │
              ▼                        ▼
     ┌────────────────┐        Result → DynamoDB
     │  Model Select  │        Client polls GET /v1/requests/{id}
     │  (AppConfig    │
     │   filtered)    │
     └────────┬───────┘
              ▼
     ┌────────────────────────────────────────┐
     │            Model Pool                   │
     ├──────────────────┬─────────────────────┤
     │ Simple:          │ Moderate:           │
     │  Nova Lite       │  Nova Pro           │
     │                  │  Sonnet 4.6         │
     ├──────────────────┼─────────────────────┤
     │ Complex (async): │ Specialized:        │
     │  Opus 4.6        │  Sonnet 4.6         │
     │  Sonnet 4.6      │                     │
     └──────────────────┴─────────────────────┘
```

## Key Features

- **Dynamic Complexity Routing**: Classifies prompts and routes to appropriately-sized models
- **Auto Async Detection**: Complex requests automatically dispatch asynchronously (client polls for results)
- **Hot-Swap via AppConfig**: Enable/disable models, adjust traffic splits, and activate kill switches without deployments
- **ISO 42001 Compliance**: Content guardrails, PII protection, transparency APIs, human oversight, governance documentation
- **Adaptive Feedback Loop**: Model weights adjust based on observed latency, quality, and error rates
- **Circuit Breaker**: Automatic failover when a model/provider degrades
- **OpenAI-Compatible API**: Drop-in replacement with routing metadata in responses

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
│   ├── appconfig.tf                  # Hot-swap routing feature flags
│   ├── async_processing.tf          # Async request processing (DynamoDB + Lambda)
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
├── agent/                            # Router agent container (ARM64)
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app.py                        # Routing logic + AppConfig integration
├── lambda/
│   ├── api_proxy/                    # Proxies API GW → AgentCore (sync + async dispatch)
│   ├── async_processor/              # Long-running model invocations (Opus, 15 min)
│   ├── complexity_classifier/        # Classifies prompt complexity
│   ├── model_invoker/                # Invokes selected model
│   ├── feedback_collector/           # Records quality metrics
│   ├── weight_adjuster/              # Kinesis consumer, adjusts model weights
│   ├── data_classifier/              # Scans for PII, enforces data residency
│   ├── human_override/               # Kill switch, block/pin models, report concerns
│   └── transparency_api/             # Routing explanations, audit log, model info
└── scripts/
    ├── deploy.sh                     # Full build + push + apply (two-phase)
    ├── get-token.sh                  # Get Cognito auth token + quick test
    └── run-tests.sh                  # Comprehensive test suite (26 tests)
```

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.5.0 (tested with 1.13.1)
- AWS Provider 6.54.0+
- Docker with buildx and QEMU support (for ARM64 cross-compilation)
- Bedrock model access enabled (Nova Lite, Nova Pro, Claude Sonnet 4.6)
- jq (for test scripts)

### One-Time Setup

**Enable Docker ARM64 cross-compilation** (required on Intel/AMD machines):
```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

**Activate models**: The first time you use a model, Bedrock auto-enables it. For Anthropic models, you may need to invoke once from an account with AWS Marketplace permissions. Open the model in Bedrock Playground to trigger activation.

**Models used**:
| Model | Inference Profile ID | Tier |
|-------|---------------------|------|
| Amazon Nova Lite | `us.amazon.nova-lite-v1:0` | Simple + Classifier |
| Amazon Nova Pro | `us.amazon.nova-pro-v1:0` | Moderate |
| Claude Sonnet 4.6 | `us.anthropic.claude-sonnet-4-6` | Moderate + Fallback |
| Claude Opus 4.6 | `us.anthropic.claude-opus-4-6-v1` | Complex (async only) |

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

**Note**: ECR login tokens expire after 12 hours. If you get `403 Forbidden` on push, re-run the `get-login-password` command.

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
| `GET` | `/v1/requests/{requestId}` | Poll for async request results |
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

**Synchronous Request (simple/moderate prompts):**
```json
{
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What is the capital of France?"}
  ],
  "routing": {
    "policy": "default",
    "max_cost": 0.01
  }
}
```

**Synchronous Response (200):**
```json
{
  "id": "chatcmpl-abc123",
  "model": "us.amazon.nova-pro-v1:0",
  "choices": [{
    "message": {"role": "assistant", "content": "The capital of France is Paris."},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 15, "completion_tokens": 8, "total_tokens": 23},
  "routing": {
    "complexity": "simple",
    "model_selected": "us.amazon.nova-lite-v1:0",
    "provider": "bedrock",
    "latency_ms": 890,
    "escalated": false
  }
}
```

**Async Response (202 — auto-detected complex or explicit `"async": true`):**
```json
{
  "id": "chatcmpl-abc123",
  "status": "pending",
  "message": "Request accepted for async processing. Poll for results.",
  "poll_url": "/v1/requests/abc123",
  "request_id": "abc123"
}
```

**Poll Response (200 — completed):**
```json
{
  "id": "chatcmpl-abc123",
  "status": "completed",
  "model": "us.anthropic.claude-opus-4-6-v1",
  "choices": [{
    "message": {"role": "assistant", "content": "...detailed response..."},
    "finish_reason": "stop"
  }],
  "routing": {"complexity": "complex", "model_selected": "us.anthropic.claude-opus-4-6-v1"}
}
```

**Response Headers (Transparency):**
```
X-AI-Model: us.amazon.nova-pro-v1:0
X-AI-Provider: bedrock
X-AI-Routed: true
X-AI-Complexity: moderate
X-AI-Disclosure: Response generated by dynamically-selected AI model.
```

## Sync vs Async Routing

The router automatically decides whether to process synchronously or asynchronously:

| Request Type | Routing | Response | Use Case |
|---|---|---|---|
| Simple/moderate prompts | Sync (Nova Lite/Pro, Sonnet) | 200 immediate | Chat, quick Q&A |
| Complex prompts (auto-detected) | Async (Opus) | 202 + poll | Deep reasoning, code generation |
| Explicit `"async": true` | Async (any model) | 202 + poll | Client knows it wants async |

**Auto-detection** uses heuristics: prompts with multiple complexity indicators (design, prove, algorithm, pseudocode, etc.) and sufficient length automatically dispatch to the async path.

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
| `quality_maximized` | Always pick most capable model |
| `cascade` | Try cheap first, escalate if confidence is low |

Policies are stored in DynamoDB and can be updated without redeployment.

## Hot-Swap with AppConfig

The router reads feature flags from AWS AppConfig every 30 seconds. Changes take effect without any deployment or restart.

### Routing Configuration Flags

| Flag | What it controls |
|------|-----------------|
| `enable_nova_lite` | Enable/disable Nova Lite in model pool |
| `enable_nova_pro` | Enable/disable Nova Pro |
| `enable_claude_sonnet` | Enable/disable Sonnet 4.6 |
| `enable_claude_opus` | Enable/disable Opus 4.6 |
| `enable_external_openai` | Enable/disable external provider routing |
| `enable_sagemaker` | Enable/disable SageMaker endpoint |
| `cascade_enabled` | Toggle cascade/escalation + confidence threshold |
| `circuit_breaker` | Failure threshold + recovery timeout |
| `traffic_split` | Percentage distribution across models |

### Kill Switch Flags

| Flag | What it controls |
|------|-----------------|
| `system_active` | Master on/off for the entire system |
| `bedrock_provider_active` | Enable/disable all Bedrock models |
| `external_provider_active` | Enable/disable external providers |
| `sagemaker_provider_active` | Enable/disable SageMaker |
| `human_review_required` | Force human review for specified categories |

### How to Hot-Swap

**Via AWS Console**: AppConfig → Applications → `llm-router-dev-config` → Edit flags → Deploy

**Via CLI** (example: disable Opus):
```bash
# The router will stop using Opus within 30 seconds
# Update feature flags and deploy via AppConfig
```

**Via Admin API** (emergency):
```bash
curl -X POST "https://your-api/v1/admin/override" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"action":"kill_switch","parameters":{"target":"system","enabled":false},"reason":"Emergency shutdown"}'
```

### Deployment Strategies

| Environment | Rollout Speed | Rollback |
|---|---|---|
| dev | Instant (0 min) | Manual |
| prod | 10 min linear (20% increments) | Auto on CloudWatch alarm |

## ISO 42001 Compliance

Built-in components addressing ISO/IEC 42001:2023 (AI Management Systems):

| Component | Controls | What it does |
|-----------|----------|--------------|
| Bedrock Guardrails | A.9.4, A.7.5 | Content filtering, PII masking, topic blocking, prompt attack detection |
| Data Classification | A.7.5, A.7.6 | Scans for PII before external routing, enforces data residency, logs decisions |
| Provenance Logging | A.7.6 | Full lineage record per request: who, what, why, how, where, model provenance |
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
- **Kinesis**: Real-time routing event stream feeding the adaptive weight-adjustment Lambda (both sync and async paths publish)
- **AgentCore Native**: Built-in OpenTelemetry instrumentation (auto-enabled, no config needed)
- **Provenance/Lineage**: Every routing decision writes a full lineage record to DynamoDB (see Data Provenance below)

## Data Provenance & Lineage (ISO 42001 A.7.6)

Every routing decision — sync and async — writes a provenance record to the `routing-audit-log` DynamoDB table. This provides full lineage tracking for compliance audits.

### What's Recorded

| Category | Fields | Purpose |
|----------|--------|---------|
| **WHO** | `user_id`, `session_id` | Who made the request |
| **WHAT** | `prompt_hash`, `model_id`, `input_tokens`, `output_tokens` | What was processed (prompt hashed, not stored raw) |
| **WHY** | `complexity`, `classification_method`, `policy_id`, `candidates_considered`, `model_scores` | Why this model was selected |
| **HOW** | `routing_strategy`, `is_async`, `escalated`, `latency_ms`, `estimated_cost` | How the decision was made |
| **WHERE** | `data_residency`, `external_provider`, `pii_detected` | Where data flowed (region, stayed in AWS or not) |
| **MODEL PROVENANCE** | `provider_name`, `model_family`, `inference_profile`, `data_retention` | Who made the model, its lineage |
| **CONFIG STATE** | `appconfig_state.system_active`, `appconfig_state.model_enabled` | What feature flags were active at decision time |

### Access Points

| Method | Endpoint | Who |
|--------|----------|-----|
| `GET /v1/audit/my-requests` | User's own routing history | End users |
| `GET /v1/routing/explain/{requestId}` | Full decision explanation | End users |
| DynamoDB console / queries | Full audit access | Admins/auditors |

### Retention

- 90-day TTL on all records (configurable)
- Point-in-time recovery enabled for disaster recovery
- GSIs on `user_id` and `session_id` for efficient queries

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

Runs 26 tests across 10 categories:

| # | Category | What it validates |
|---|----------|-------------------|
| 1 | Health & Connectivity | Endpoints respond, auth enforcement works |
| 2 | Basic Routing | Simple prompts route to cheap models, return content |
| 3 | Complexity-Based Routing | Moderate → Nova Pro, Complex → auto-async with Opus |
| 4 | Routing Policies | Default, budget-conscious, enterprise, cost overrides |
| 5 | Multi-Turn Conversation | System prompts, context retention across turns |
| 6 | Transparency API | Model info, user audit log, routing explanations |
| 7 | Human Oversight API | Concern reporting, admin override actions |
| 8 | Response Headers | X-AI-Model and X-AI-Routed disclosure headers |
| 9 | Error Handling | Empty messages, invalid policy, malformed JSON |
| 10 | Guardrails | Medical advice topic blocking |

To skip the login prompt on repeated runs:
```bash
export LLM_ROUTER_TOKEN="<your-access-token>"
./scripts/run-tests.sh
```

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

## Updating the Agent

When you change `agent/app.py`, rebuild and redeploy:

```bash
# Re-authenticate to ECR (tokens expire after 12h)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 339712707840.dkr.ecr.us-east-1.amazonaws.com

# Build ARM64 image and push
docker build --platform linux/arm64 -t $(cd terraform && terraform output -raw ecr_repository_url):latest agent/
docker push $(cd terraform && terraform output -raw ecr_repository_url):latest

# Force AgentCore to pull new image (destroy + recreate runtime)
cd terraform
terraform destroy -target=aws_bedrockagentcore_agent_runtime.router
terraform apply
```

Wait 4-5 minutes for the new container to start before testing.

## CLI Usage Examples

First, set up your environment:

```bash
# Get API endpoint
export API_URL=$(cd terraform && terraform output -raw api_endpoint)

# Get auth token (replace YOUR_PASSWORD)
export LLM_ROUTER_TOKEN=$(cd terraform && aws cognito-idp initiate-auth \
  --region us-east-1 \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id $(terraform output -raw cognito_web_client_id) \
  --auth-parameters USERNAME=testuser,PASSWORD=YOUR_PASSWORD \
  --query 'AuthenticationResult.AccessToken' --output text)
```

### Simple Question (routes to Nova Lite)

```bash
curl -s -X POST "$API_URL/v1/chat/completions" \
  -H "Authorization: Bearer $LLM_ROUTER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What is the speed of light?"}]}' | python3 -m json.tool
```

### Moderate Question (routes to Nova Pro)

```bash
curl -s -X POST "$API_URL/v1/chat/completions" \
  -H "Authorization: Bearer $LLM_ROUTER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Explain the differences between TCP and UDP, including when you would choose each for a networked application."}]}' | python3 -m json.tool
```

### With System Prompt

```bash
curl -s -X POST "$API_URL/v1/chat/completions" \
  -H "Authorization: Bearer $LLM_ROUTER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "messages":[
      {"role":"system","content":"You are a concise technical writer. Respond in bullet points."},
      {"role":"user","content":"What are the SOLID principles in software engineering?"}
    ]
  }' | python3 -m json.tool
```

### Force a Specific Policy

```bash
# Budget-conscious (cheapest model that works)
curl -s -X POST "$API_URL/v1/chat/completions" \
  -H "Authorization: Bearer $LLM_ROUTER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "messages":[{"role":"user","content":"Summarize the benefits of microservices."}],
    "routing":{"policy":"budget_conscious"}
  }' | python3 -m json.tool

# Enterprise (highest quality)
curl -s -X POST "$API_URL/v1/chat/completions" \
  -H "Authorization: Bearer $LLM_ROUTER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "messages":[{"role":"user","content":"Review this architecture for security vulnerabilities."}],
    "routing":{"policy":"enterprise"}
  }' | python3 -m json.tool
```

### Async Request (for complex/long-running tasks)

```bash
# Submit async request
RESPONSE=$(curl -s -X POST "$API_URL/v1/chat/completions" \
  -H "Authorization: Bearer $LLM_ROUTER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "messages":[{"role":"user","content":"Write a comprehensive comparison of React, Vue, and Angular for enterprise applications."}],
    "routing":{"async":true}
  }')

echo "$RESPONSE" | python3 -m json.tool

# Extract request ID and poll
REQUEST_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['request_id'])")

# Poll until complete (repeat every 10 seconds)
curl -s -H "Authorization: Bearer $LLM_ROUTER_TOKEN" \
  "$API_URL/v1/requests/$REQUEST_ID" | python3 -m json.tool
```

### Check Which Model Was Used

```bash
# Response headers show the model (use -i for headers)
curl -s -i -X POST "$API_URL/v1/chat/completions" \
  -H "Authorization: Bearer $LLM_ROUTER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello!"}]}' 2>&1 | grep -i "x-ai-"
```

### View Your Routing History

```bash
curl -s -H "Authorization: Bearer $LLM_ROUTER_TOKEN" \
  "$API_URL/v1/audit/my-requests" | python3 -m json.tool
```

### See Available Models

```bash
curl -s -H "Authorization: Bearer $LLM_ROUTER_TOKEN" \
  "$API_URL/v1/models/info" | python3 -m json.tool
```

### Report a Concern About a Response

```bash
curl -s -X POST "$API_URL/v1/concerns/report" \
  -H "Authorization: Bearer $LLM_ROUTER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "request_id":"YOUR_REQUEST_ID_HERE",
    "type":"inaccurate",
    "description":"The response contained incorrect information about X",
    "severity":"standard"
  }' | python3 -m json.tool
```

## Adding New Models

To add a new model or provider to the routing pool:

### Required Files

**1. `agent/app.py`** — Three changes:

```python
# Add cost (per 1K input tokens)
MODEL_COSTS = {
    ...
    "us.your-new-model-id": 0.005,
}

# Add to the appropriate tier(s)
DEFAULT_MODEL_TIERS = {
    "moderate": [
        ...,
        "us.your-new-model-id",
    ],
}

# Add AppConfig flag mapping (in AppConfigManager.is_model_enabled)
model_flag_map = {
    ...
    "us.your-new-model-id": "enable_new_model",
}
```

**2. `terraform/appconfig.tf`** — Add a feature flag:

```hcl
# In flags:
enable_new_model = {
  name = "Enable New Model"
  attributes = { enabled = { constraints = { type = "boolean" } } }
}

# In values:
enable_new_model = { enabled = true }
```

**3. `terraform/iam.tf`** — Usually no change needed (wildcards cover all Bedrock inference profiles). Only needed for non-Bedrock providers.

### Recommended Files

**4. `lambda/transparency_api/index.py`** — Add to `MODEL_INFO` dict for `GET /v1/models/info`

**5. `terraform/governance.tf`** — Add to `model_cards_index` S3 object for ISO 42001 documentation

### After Changes

```bash
# Rebuild agent image
docker build --platform linux/arm64 -t $(cd terraform && terraform output -raw ecr_repository_url):latest agent/
docker push $(cd terraform && terraform output -raw ecr_repository_url):latest

# Apply AppConfig flag changes
cd terraform && terraform apply

# Force runtime to pull new image
terraform destroy -target=aws_bedrockagentcore_agent_runtime.router
terraform apply
```

### Notes

- Bedrock models use inference profile IDs (`us.` prefix for US region)
- Find available profiles: `aws bedrock list-inference-profiles --region us-east-1`
- Legacy/retired models will return `ResourceNotFoundException` — verify with a test invoke first
- The Kinesis pipeline, weight adjuster, and audit logging work generically with any model ID

## Cleanup

```bash
cd terraform
terraform destroy
```

## Known Limitations

- **Opus sync timeout**: Claude Opus takes >30s for complex prompts, exceeding API Gateway's limit. Complex requests are automatically dispatched async.
- **AgentCore image updates**: Changing env vars triggers a new runtime version, but ECR image tag changes (`latest`) require destroy + recreate to force a pull.
- **AppConfig polling**: Feature flag changes take up to 30 seconds to take effect (cache TTL).
- **Model availability**: Bedrock inference profiles use `us.` prefix (region-scoped). Cross-region models need `global.` prefix profiles.

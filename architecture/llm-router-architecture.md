# Dynamic LLM Router Architecture on AWS

## Overview

This architecture enables dynamic model selection and provider switching — routing each inference request to the optimal LLM based on task complexity, cost constraints, latency requirements, and quality thresholds. It leverages **Amazon Bedrock AgentCore** as the core runtime substrate for hosting the routing agents, with AgentCore Gateway providing unified, secure access to multiple model providers.

---

## Architecture Diagram (Logical)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              Client Applications                                 │
│           (Web Apps, Mobile, CLI, Internal Services, Other Agents)               │
└─────────────────────────────┬───────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         API Gateway (Amazon API Gateway)                          │
│                    Rate limiting, auth, request validation                        │
└─────────────────────────────┬───────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    AgentCore Gateway (Unified Entry Point)                        │
│  ┌────────────────┐  ┌──────────────────┐  ┌─────────────────────────────────┐  │
│  │ Ingress Auth   │  │ Semantic Routing  │  │ Inference Target Composition    │  │
│  │ (OAuth2/IAM)   │  │ & Tool Discovery │  │ (Multi-provider model routing)  │  │
│  └────────────────┘  └──────────────────┘  └─────────────────────────────────┘  │
└─────────────────────────────┬───────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     AgentCore Runtime (Router Agent)                              │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                      ROUTER AGENT (Strands/LangGraph)                    │    │
│  │                                                                          │    │
│  │  ┌───────────────┐  ┌──────────────────┐  ┌────────────────────────┐   │    │
│  │  │  Classifier   │  │  Policy Engine   │  │   Model Selector       │   │    │
│  │  │  (Complexity   │  │  (Cost budgets,  │  │   (Weighted scoring,   │   │    │
│  │  │   analysis)   │  │   SLA rules,     │  │    fallback chains)    │   │    │
│  │  │               │  │   rate limits)   │  │                        │   │    │
│  │  └───────┬───────┘  └────────┬─────────┘  └───────────┬────────────┘   │    │
│  │          │                    │                         │                │    │
│  │          └────────────────────┼─────────────────────────┘                │    │
│  │                               ▼                                          │    │
│  │                    ┌─────────────────────┐                               │    │
│  │                    │  Dispatch Decision   │                               │    │
│  │                    └──────────┬──────────┘                               │    │
│  └───────────────────────────────┼──────────────────────────────────────────┘    │
│                                  │                                                │
│  ┌───────────────────────────────┼──────────────────────────────────────────┐    │
│  │              AgentCore Memory (Session & Routing State)                    │    │
│  │  • Conversation context   • Routing history   • Cost accumulation         │    │
│  └───────────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────┬───────────────────────────────────────────────────┘
                              │
              ┌───────────────┼────────────────────────┐
              │               │                        │
              ▼               ▼                        ▼
┌──────────────────┐ ┌─────────────────┐ ┌─────────────────────────┐
│  Amazon Bedrock  │ │  Self-hosted     │ │  External Providers     │
│  Models          │ │  Models (SageMk) │ │  (via Gateway egress)   │
│                  │ │                  │ │                         │
│ • Claude 4/3.5  │ │ • Fine-tuned     │ │ • OpenAI (GPT-4o/mini) │
│ • Nova Pro/Lite │ │   domain models  │ │ • Cohere               │
│ • Llama 4       │ │ • Llama on EKS   │ │ • Mistral (direct)     │
│ • Mistral Large │ │ • vLLM clusters  │ │ • Google (Gemini)      │
└──────────────────┘ └─────────────────┘ └─────────────────────────┘
```

---

## Core Components

### 1. AgentCore Gateway — Unified Ingress & Model Composition

AgentCore Gateway acts as the single secure entry point. It provides:

- **Inference targets**: Routes model requests across multiple providers (Bedrock, SageMaker endpoints, external APIs) through one endpoint. This is the native AWS mechanism for multi-provider model routing.
- **Ingress/egress authentication**: Handles OAuth2 flows for external providers, IAM for AWS services, and API key management — no credential handling in application code.
- **Semantic tool selection**: As the router agent's toolkit grows, Gateway helps it discover the right tools based on task context.
- **Protocol translation**: Converts between MCP, OpenAPI, and direct HTTP for seamless provider interop.

### 2. AgentCore Runtime — The Router Agent

The Router Agent is a containerized agent hosted on AgentCore Runtime. It implements the routing decision logic:

```python
# Conceptual router agent (Strands Agents framework)
from strands import Agent, tool
from strands.models import BedrockModel

@tool
def classify_complexity(prompt: str, context: dict) -> str:
    """Classify the request as simple, moderate, or complex."""
    # Uses a lightweight model (Nova Lite) to classify
    # Returns: "simple" | "moderate" | "complex" | "specialized"
    pass

@tool
def select_model(complexity: str, policy: dict, budget_remaining: float) -> dict:
    """Select optimal model based on complexity, policy constraints, and budget."""
    routing_table = {
        "simple": [
            {"model": "amazon.nova-lite-v1", "cost_per_1k": 0.0002, "provider": "bedrock"},
            {"model": "anthropic.claude-3-haiku", "cost_per_1k": 0.00025, "provider": "bedrock"},
        ],
        "moderate": [
            {"model": "anthropic.claude-sonnet-4", "cost_per_1k": 0.003, "provider": "bedrock"},
            {"model": "amazon.nova-pro-v1", "cost_per_1k": 0.001, "provider": "bedrock"},
        ],
        "complex": [
            {"model": "anthropic.claude-opus-4", "cost_per_1k": 0.015, "provider": "bedrock"},
            {"model": "openai.gpt-4o", "cost_per_1k": 0.005, "provider": "external"},
        ],
        "specialized": [
            {"model": "custom-finetuned-v2", "cost_per_1k": 0.008, "provider": "sagemaker"},
        ],
    }
    # Apply policy filters, budget checks, latency SLA
    candidates = routing_table[complexity]
    return score_and_select(candidates, policy, budget_remaining)

router_agent = Agent(
    model=BedrockModel("amazon.nova-lite-v1"),  # Lightweight model for routing decisions
    tools=[classify_complexity, select_model, invoke_model, track_cost],
    system_prompt="You are an LLM routing agent. Classify requests and dispatch them optimally."
)
```

**Key design choice**: The Router Agent itself uses a fast, cheap model (Nova Lite or Haiku) to make routing decisions. The expensive model is only invoked for the actual user request.

### 3. AgentCore Memory — Routing State & Context

AgentCore Memory maintains:

- **Session context**: Conversation history for multi-turn requests, so the router can maintain model consistency within a session.
- **Budget tracking**: Per-tenant/per-session cost accumulation against allocated budgets.
- **Routing history**: Which models were selected and their response quality scores, feeding the adaptive routing loop.
- **Fallback state**: Tracks provider outages and degraded performance for circuit-breaker logic.

### 4. Routing Policy Store (DynamoDB + AppConfig)

Externalized configuration that controls routing behavior without redeployment:

```json
{
  "policies": {
    "default": {
      "max_cost_per_request": 0.05,
      "max_latency_ms": 3000,
      "quality_threshold": 0.8,
      "fallback_chain": ["bedrock/claude-sonnet", "bedrock/nova-pro", "bedrock/nova-lite"]
    },
    "enterprise_tier": {
      "max_cost_per_request": 0.50,
      "max_latency_ms": 30000,
      "quality_threshold": 0.95,
      "preferred_providers": ["bedrock", "sagemaker"],
      "fallback_chain": ["bedrock/claude-opus", "bedrock/claude-sonnet"]
    },
    "budget_conscious": {
      "max_cost_per_request": 0.005,
      "max_latency_ms": 5000,
      "quality_threshold": 0.6,
      "fallback_chain": ["bedrock/nova-lite", "bedrock/nova-micro"]
    }
  }
}
```

### 5. Observability & Feedback Loop (AgentCore Observability + CloudWatch)

AgentCore's built-in observability provides tracing for every routing decision. Combined with a feedback pipeline:

```
Router Decision → Model Invocation → Response → Quality Evaluation → Metrics
        ↑                                                                │
        └────────────── Adaptive Weight Adjustment ◄─────────────────────┘
```

- **CloudWatch Metrics**: Latency, cost, error rates per model/provider.
- **AgentCore Evaluations**: Automated quality scoring of model responses.
- **Kinesis Data Stream**: Real-time routing events for analytics and weight adjustment.

---

## Routing Strategies

The Router Agent supports multiple strategies, selectable per policy:

| Strategy | Description | Best For |
|----------|-------------|----------|
| **Complexity-based** | Classify prompt difficulty, route to appropriately sized model | General workloads with mixed complexity |
| **Cost-optimized** | Minimize cost while meeting quality threshold | Budget-constrained applications |
| **Latency-optimized** | Route to fastest-responding provider | Real-time chat, streaming UIs |
| **Quality-maximized** | Always route to highest-capability model | Critical business decisions |
| **Round-robin with weights** | Distribute load across providers based on configurable weights | A/B testing, gradual rollouts |
| **Cascade/Fallback** | Try cheapest model first, escalate if confidence is low | Cost-sensitive with quality floor |

### Cascade Pattern (detailed)

```
Request → Nova Lite → Confidence check
                         │
                    ≥ threshold? ──Yes──→ Return response
                         │
                        No
                         ▼
              Claude Sonnet → Confidence check
                                  │
                             ≥ threshold? ──Yes──→ Return response
                                  │
                                 No
                                  ▼
                        Claude Opus → Return response
```

---

## Provider Switching & Failover

### Circuit Breaker Pattern

```python
class ProviderCircuitBreaker:
    """Tracks provider health and triggers failover."""
    
    def __init__(self, failure_threshold=3, recovery_timeout_s=60):
        self.failure_count = {}
        self.state = {}  # "closed" | "open" | "half-open"
        self.failure_threshold = failure_threshold
        self.recovery_timeout_s = recovery_timeout_s
    
    def record_failure(self, provider: str):
        self.failure_count[provider] = self.failure_count.get(provider, 0) + 1
        if self.failure_count[provider] >= self.failure_threshold:
            self.state[provider] = "open"  # Stop routing to this provider
            self.schedule_recovery_probe(provider)
    
    def record_success(self, provider: str):
        self.failure_count[provider] = 0
        self.state[provider] = "closed"
    
    def can_route(self, provider: str) -> bool:
        return self.state.get(provider, "closed") != "open"
```

When a provider becomes unavailable:
1. Circuit breaker opens after N consecutive failures.
2. Requests automatically failover to next provider in the fallback chain.
3. Half-open probe periodically tests recovery.
4. CloudWatch alarm triggers SNS notification to ops.

### Hot-Swap Configuration

Using AWS AppConfig with feature flags, you can:
- Instantly redirect all traffic away from a provider (planned maintenance, cost spike).
- Gradually shift traffic to a new model (canary deployment).
- Enable/disable providers per tenant without restarts.

---

## Data Flow

```
1. Client sends request with optional routing hints:
   POST /v1/chat/completions
   {
     "messages": [...],
     "routing": {
       "policy": "default",          // optional policy override
       "max_cost": 0.01,             // optional per-request budget
       "prefer_provider": "bedrock"  // optional preference
     }
   }

2. API Gateway validates auth, applies rate limits, forwards to AgentCore Gateway.

3. AgentCore Gateway authenticates, applies ingress rules, routes to Router Agent.

4. Router Agent:
   a. Retrieves session state from AgentCore Memory
   b. Classifies request complexity (fast model call, ~20ms)
   c. Loads applicable policy from DynamoDB/AppConfig
   d. Scores candidate models (cost × latency × quality × availability)
   e. Selects target model
   f. Invokes target model via Gateway inference targets
   g. (Optional) Evaluates response confidence; escalates if below threshold
   h. Streams response back to client
   i. Logs routing decision + metrics to Observability

5. Async: Kinesis event triggers Lambda that updates model performance weights.
```

---

## Infrastructure (CDK Sketch)

```typescript
import * as cdk from 'aws-cdk-lib';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as kinesis from 'aws-cdk-lib/aws-kinesis';
import * as agentcore from 'aws-cdk-lib/aws-bedrock-agentcore';

export class LlmRouterStack extends cdk.Stack {
  constructor(scope: cdk.App, id: string) {
    super(scope, id);

    // Router Agent Runtime
    const routerRuntime = new agentcore.Runtime(this, 'RouterAgentRuntime', {
      image: 'router-agent:latest',  // Container with routing logic
      memory: 512,
      timeout: cdk.Duration.seconds(60),
      scaling: {
        minInstances: 2,
        maxInstances: 50,
        targetConcurrency: 10,
      },
    });

    // AgentCore Gateway with inference targets
    const gateway = new agentcore.Gateway(this, 'LlmRouterGateway', {
      targets: [
        // Bedrock models (native)
        {
          type: 'inference',
          name: 'bedrock-claude-opus',
          modelId: 'anthropic.claude-opus-4-20250514',
        },
        {
          type: 'inference',
          name: 'bedrock-claude-sonnet',
          modelId: 'anthropic.claude-sonnet-4-20250514',
        },
        {
          type: 'inference',
          name: 'bedrock-nova-pro',
          modelId: 'amazon.nova-pro-v1:0',
        },
        {
          type: 'inference',
          name: 'bedrock-nova-lite',
          modelId: 'amazon.nova-lite-v1:0',
        },
        // SageMaker endpoint (self-hosted)
        {
          type: 'http',
          name: 'sagemaker-custom',
          endpoint: 'https://runtime.sagemaker.us-east-1.amazonaws.com/endpoints/custom-model/invocations',
          auth: { type: 'iam' },
        },
        // External provider (API key via credential exchange)
        {
          type: 'http',
          name: 'external-openai',
          endpoint: 'https://api.openai.com/v1/chat/completions',
          auth: { type: 'api-key', secretArn: 'arn:aws:secretsmanager:us-east-1:123456789:secret:openai-key' },
        },
        // Router Agent itself
        {
          type: 'agentcore-runtime',
          name: 'router-agent',
          runtime: routerRuntime,
        },
      ],
      authentication: {
        ingress: { type: 'iam' },
      },
    });

    // Memory for session state
    const memory = new agentcore.Memory(this, 'RouterMemory', {
      retentionDays: 7,
    });

    // Policy store
    const policyTable = new dynamodb.Table(this, 'RoutingPolicies', {
      partitionKey: { name: 'policyId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
    });

    // Metrics & feedback pipeline
    const routingStream = new kinesis.Stream(this, 'RoutingEvents', {
      shardCount: 2,
    });
  }
}
```

---

## Why AgentCore for This

| Concern | AgentCore Solution |
|---------|-------------------|
| **Runtime hosting** | Serverless containers with per-session microVM isolation, auto-scaling |
| **Multi-provider connectivity** | Gateway composes inference targets across Bedrock, SageMaker, and external APIs in one endpoint |
| **Session state** | AgentCore Memory persists conversation context and routing state across turns |
| **Auth complexity** | Gateway handles OAuth2, IAM, API keys for each provider — no credential code in your agent |
| **Observability** | Built-in tracing of every routing decision, model invocation, and latency metric |
| **Framework flexibility** | Use Strands, LangGraph, CrewAI, or raw Python — AgentCore is framework-agnostic |
| **Scaling** | Handles burst traffic without provisioning; scales to zero when idle |
| **Policy enforcement** | AgentCore Policy component for guardrails; Gateway rules for access control |

---

## Comparison with Bedrock Intelligent Prompt Routing

| Feature | Bedrock Intelligent Prompt Routing | This Architecture |
|---------|-----------------------------------|-------------------|
| Scope | Routes within a single model family (e.g., Haiku ↔ Sonnet) | Routes across families, providers, and self-hosted models |
| Customization | AWS-managed routing logic, limited control | Fully customizable policies, weights, strategies |
| External providers | No | Yes (OpenAI, Google, Cohere, etc. via Gateway) |
| Cost controls | Implicit (cheaper model when possible) | Explicit per-request budgets, tenant quotas, alerts |
| Cascade/escalation | No | Yes, with confidence-based escalation |
| Self-hosted models | No | Yes (SageMaker, EKS, vLLM endpoints) |
| Feedback loop | No | Yes, adaptive weight adjustment from quality signals |

Bedrock's built-in Intelligent Prompt Routing is a good starting point for simple within-family optimization. This architecture extends that concept to a full cross-provider, policy-driven routing layer when you need more control.

---

## Deployment Considerations

- **Cold start**: Keep minimum 2 instances of the Router Agent warm for sub-second routing decisions.
- **Classifier model**: Use the fastest/cheapest model available (Nova Lite, ~20ms) for the classification step to keep routing overhead under 50ms.
- **Regional failover**: Deploy in 2+ regions with Route 53 health checks for provider-level regional outages.
- **Cost guardrails**: Set CloudWatch billing alarms and AppConfig kill switches per provider.
- **Testing**: Use AgentCore Evaluations to run offline benchmarks of routing accuracy against labeled datasets before deploying new policies.
- **Streaming**: The Gateway supports streaming responses — the Router Agent should pass through SSE streams from the target model to the client without buffering.

---

## ISO 42001 Compliance Layer

The architecture includes dedicated components addressing ISO/IEC 42001:2023 AIMS requirements:

### Content Guardrails (A.9.4, A.7.5)

```
Request → [Bedrock Guardrails: Content Filter + PII Detection] → Router Agent
                                                                       │
                                                                       ▼
                                                              [Model Invocation]
                                                                       │
                                                                       ▼
Response ← [Bedrock Guardrails: Output Filter + Grounding Check] ← Model Response
```

Two guardrail configurations:
- **Standard**: Applied to all invocations — filters harmful content (hate, violence, sexual, misconduct, prompt attacks), masks PII in responses, blocks prohibited topics (medical/legal/financial advice), detects prompt injection.
- **External Routing**: Stricter PII blocking applied before any request is sent to non-AWS providers. Blocks (not masks) all PII categories to enforce data residency.

### Data Classification Engine (A.7.5, A.7.6)

Before routing to external providers, a data classification step:
1. Regex scan for PII patterns (email, phone, SSN, credit card, AWS keys)
2. Domain keyword detection (health, financial, legal content)
3. Bedrock Guardrails deep PII scan
4. **Decision**: Block external routing if sensitive data detected; force to internal provider
5. **Audit**: Log every classification decision to Data Flow Log table (90-day retention)

### Data Provenance & Lineage (A.7.6)

Every routing decision (sync and async) writes a full provenance record:
- **WHO**: User ID, session ID
- **WHAT**: Prompt hash (not raw text), model selected, token counts
- **WHY**: Complexity classification, method used, policy applied, all candidates scored
- **HOW**: Routing strategy, sync/async path, escalation status, latency, cost
- **WHERE**: Data residency (region), whether data left AWS, PII detection result
- **MODEL PROVENANCE**: Provider name, model family, inference profile, data retention policy
- **CONFIG STATE**: AppConfig feature flags active at decision time

Records are queryable by user (via Transparency API) and by admin (via DynamoDB GSIs).

### Human Oversight (A.9.5)

- **Kill Switch**: AppConfig feature flags allow operators to instantly disable the entire system, individual providers, or specific models — no deployment required.
- **Override API**: Operators can pin models, block models, or require human review for specific categories via `POST /v1/admin/override`.
- **Concern Reporting**: Users can report problematic outputs via `POST /v1/concerns/report`, which queues them for human review with SLA tracking (4h critical, 24h standard).
- **Review Queue**: DynamoDB + SQS queue for flagged items with CloudWatch alarm if backlog grows beyond threshold.
- **Escalation**: Critical concerns trigger SNS notification to ops team immediately.

### Transparency & Explainability (A.8)

- **Mandatory Headers**: Every response includes `X-AI-Model`, `X-AI-Provider`, `X-AI-Routed`, and `X-AI-Disclosure` headers informing users of AI involvement.
- **Explain API**: `GET /v1/routing/explain/{requestId}` returns why a specific model was chosen — classification factors, candidate scores, and human-readable explanation.
- **User Audit Log**: `GET /v1/audit/my-requests` lets users see which models served their requests over the past 90 days.
- **Model Cards**: `GET /v1/models/info` returns capabilities, limitations, known biases, and data residency info for all models in the pool.

### Governance Documentation (A.2, A.5, A.6.2.9)

Versioned, encrypted S3 bucket containing:
- **AI Policy**: Responsible AI principles, compliance commitments, review schedule
- **Risk Register**: 7 identified risks with likelihood, impact, mitigations, and assigned owners
- **Impact Assessment**: Positive/negative impacts on affected parties with residual risk analysis
- **Acceptable Use Policy**: Intended use cases, prohibited uses, enforcement rules
- **Model Cards Index**: Per-model capabilities, limitations, data residency, and provider details

### ISO 42001 Control Coverage Summary

| Control Area | Coverage | Key Component |
|---|---|---|
| A.2 Policies | ✔️ | S3 governance bucket (AI Policy, Acceptable Use) |
| A.3 Organization | ✔️ | Concern reporting API, RACI in policy docs |
| A.5 Impact Assessment | ✔️ | Risk register, impact assessment in S3 |
| A.6 Lifecycle | ✔️ | Deployment controls, monitoring, model cards |
| A.7 Data | ✔️ | Data classification engine, flow log, guardrails |
| A.8 Transparency | ✔️ | Explain API, audit log, mandatory headers |
| A.9 Use | ✔️ | Kill switch, human override, content guardrails |
| A.10 Third-Party | ✔️ | External routing guardrail, provider assessment docs |

---

## Sources

- [Amazon Bedrock AgentCore Gateway documentation](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway.html)
- [Amazon Bedrock Intelligent Prompt Routing](https://aws.amazon.com/bedrock/intelligent-prompt-routing/)
- [Build scalable serverless LangGraph multi-agent systems with AgentCore](https://aws.amazon.com/blogs/machine-learning/build-highly-scalable-serverless-langgraph-multi-agent-systems-in-aws-with-amazon-bedrock-agentcore/)
- [Amazon Bedrock AgentCore Harness GA announcement](https://aws.amazon.com/blogs/machine-learning/amazon-bedrock-agentcore-harness-is-now-generally-available-go-from-idea-to-production-grade-agent-in-minutes/)

Content was rephrased for compliance with licensing restrictions.

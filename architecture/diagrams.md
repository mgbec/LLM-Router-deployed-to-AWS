# Architecture Diagrams

These Mermaid diagrams render automatically on GitHub. For PNG exports with AWS icons, see `diagrams/generate.py`.

## Request Flow (Sync)

```mermaid
sequenceDiagram
    participant C as Client
    participant AG as API Gateway
    participant P as API Proxy Lambda
    participant R as AgentCore Runtime
    participant GW as Gateway (MCP)
    participant CL as classify_complexity Lambda
    participant B as Bedrock (Model)
    participant K as Kinesis

    C->>AG: POST /v1/chat/completions
    AG->>AG: JWT Validation (Cognito)
    AG->>P: Forward request
    P->>R: invoke_agent_runtime()
    R->>GW: tools/call (classify_complexity)
    GW->>CL: Invoke Lambda
    CL->>B: converse(Nova Lite)
    B-->>CL: "moderate"
    CL-->>GW: {complexity: "moderate"}
    GW-->>R: MCP result
    R->>R: Select model (Nova Pro)
    R->>B: converse(Nova Pro, user prompt)
    B-->>R: Response text
    R->>K: put_record (metrics)
    R-->>P: JSON response
    P-->>AG: 200 + headers
    AG-->>C: Response + X-AI-Model header
```

## Request Flow (Async - Complex)

```mermaid
sequenceDiagram
    participant C as Client
    participant P as API Proxy Lambda
    participant DB as DynamoDB (async_requests)
    participant AL as Async Processor Lambda
    participant R as AgentCore Runtime
    participant B as Bedrock (Opus)

    C->>P: POST /v1/chat/completions (complex prompt)
    P->>P: Auto-detect: complex → async
    P->>DB: PutItem {status: pending}
    P->>AL: Invoke (async, fire-and-forget)
    P-->>C: 202 {poll_url, request_id}

    Note over AL,B: Background processing (up to 15 min)
    AL->>DB: UpdateItem {status: processing}
    AL->>R: invoke_agent_runtime()
    R->>B: converse(Opus 4.6)
    B-->>R: Long response
    R-->>AL: JSON result
    AL->>DB: UpdateItem {status: completed, result: {...}}

    C->>P: GET /v1/requests/{id}
    P->>DB: GetItem
    DB-->>P: {status: completed, result}
    P-->>C: 200 {choices: [...], routing: {...}}
```

## Gateway MCP Tool Flow

```mermaid
flowchart LR
    A[Agent Container] -->|"JSON-RPC<br/>tools/call"| G[AgentCore Gateway]
    G -->|"Lookup tool name<br/>{target}___{tool}"| T{Target Type}
    T -->|Lambda| L1[classify_complexity]
    T -->|Lambda| L2[classify_data_sensitivity]
    T -->|Lambda| L3[record_feedback]
    T -->|Lambda| L4[invoke_model]
    L1 -->|Response| G
    G -->|"MCP Result"| A
```

## AppConfig Hot-Swap

```mermaid
flowchart TB
    subgraph AppConfig
        RC[Routing Config<br/>Feature Flags]
        KS[Kill Switch<br/>Feature Flags]
    end

    subgraph "Agent Container"
        CM[ConfigManager<br/>polls every 30s]
    end

    subgraph "Routing Decision"
        MT[Model Tiers<br/>filtered by flags]
        CB[Circuit Breaker<br/>thresholds from config]
    end

    RC -->|"enable_nova_pro: false"| CM
    KS -->|"system_active: true"| CM
    CM --> MT
    CM --> CB
    MT -->|"Available models"| D[Select Model]
```

## Data Flow & Compliance

```mermaid
flowchart TB
    subgraph "Request Path"
        REQ[User Request] --> CLASS[Classify Complexity]
        CLASS --> SELECT[Select Model]
        SELECT --> DC{External<br/>Provider?}
        DC -->|Yes| SCAN[Data Classification<br/>PII Scan]
        SCAN -->|PII Found| BLOCK[Force Internal Model]
        SCAN -->|Clean| EXT[External Provider]
        DC -->|No| INT[Bedrock Model]
        BLOCK --> INT
    end

    subgraph "Audit Trail (A.7.6)"
        INT --> PROV[Provenance Write]
        EXT --> PROV
        PROV --> AUD[(Audit Log<br/>DynamoDB)]
        SCAN --> FLOW[(Data Flow Log<br/>DynamoDB)]
    end

    subgraph "Feedback Loop"
        INT --> KIN[Kinesis Event]
        KIN --> WA[Weight Adjuster]
        WA --> MET[(Metrics Table)]
        WA --> CW[CloudWatch]
    end

    subgraph "Human Oversight (A.9.5)"
        KS[Kill Switch] -.->|"Can disable"| SELECT
        OV[Admin Override] -.->|"Can block model"| SELECT
        REP[Concern Report] --> SQS[(Review Queue)]
    end
```

## Component Map

```mermaid
graph TB
    subgraph "Terraform Resources"
        subgraph "Compute"
            RT[AgentCore Runtime]
            GW[AgentCore Gateway]
            L1[Lambda: api_proxy]
            L2[Lambda: async_processor]
            L3[Lambda: complexity_classifier]
            L4[Lambda: data_classifier]
            L5[Lambda: feedback_collector]
            L6[Lambda: weight_adjuster]
            L7[Lambda: human_override]
            L8[Lambda: transparency_api]
        end
        subgraph "Storage"
            D1[(routing_policies)]
            D2[(routing_metrics)]
            D3[(routing_audit_log)]
            D4[(data_flow_log)]
            D5[(human_review_queue)]
            D6[(async_requests)]
            S1[S3: governance_docs]
        end
        subgraph "Integration"
            K[Kinesis Stream]
            AC[AppConfig]
            CG[Cognito]
            AG[API Gateway]
        end
        subgraph "Security"
            GR[Bedrock Guardrails x2]
            IAM[IAM Roles x10]
            AUD[Auditor Role]
        end
        subgraph "Observability"
            CW[CloudWatch Dashboard]
            XR[X-Ray Group + Rules]
            AL[Alarms x5]
            SNS[SNS Topics x2]
            SQS[SQS Queues x2]
        end
    end
```

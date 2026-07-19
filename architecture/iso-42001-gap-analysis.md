# ISO 42001 Gap Analysis — LLM Router Architecture

## Summary

ISO/IEC 42001:2023 defines requirements for an Artificial Intelligence Management System (AIMS) across 7 mandatory clauses (4–10) and 39 Annex A controls organized into 10 areas. This analysis maps the current LLM Router implementation against those requirements.

**Current coverage**: The system implements technical controls for most Annex A areas. Primary remaining gaps are organizational/procedural (roles documentation, internal audit processes, formal competency framework) rather than architectural.

**Implementation status**: 28/39 controls adequately covered, 8 partially covered, 3 remaining gaps.

---

## Gap Assessment by ISO 42001 Control Area

### Legend: ✔️ Implemented | ✅ Partially Covered | ❌ Gap Remaining

---

### A.2: Policies for AI

| Control | Status | Implementation |
|---------|--------|----------------|
| A.2.2 AI Policy | ✔️ Implemented | Formal AI Policy document stored in versioned S3 bucket (`governance.tf`). Covers responsible AI principles, fairness, transparency, accountability, data protection, safety, and environmental responsibility. Quarterly review schedule defined. |
| A.2.3 Responsible AI Topics | ✔️ Implemented | AI Policy addresses: fairness/non-discrimination, transparency, accountability, human oversight, data protection, safety, environmental responsibility. Acceptable Use Policy defines prohibited uses. |

---

### A.3: Internal Organization

| Control | Status | Implementation |
|---------|--------|----------------|
| A.3.2 Roles and Responsibilities | ✅ Partial | Risk Register assigns owners (AI Governance Board, Data Protection Officer, AI Safety Lead, Platform Engineering, Vendor Management). Gap: No formal RACI matrix or job descriptions. |
| A.3.3 Reporting AI Concerns | ✔️ Implemented | `POST /v1/concerns/report` API endpoint. SQS queue + SNS escalation. SLA tracking (4h critical, 24h standard). CloudWatch alarm on backlog. |
| A.3.4 Impact of Organizational Changes | ✅ Partial | AppConfig hot-swap enables controlled changes. Gap: No formal change impact assessment procedure documented. |

---

### A.4: Resources for AI Systems

| Control | Status | Implementation |
|---------|--------|----------------|
| A.4.2 Resources | ✔️ Implemented | Full Terraform IaC, auto-scaling AgentCore Runtime, serverless Lambdas, pay-per-request DynamoDB. |
| A.4.3 Competencies | ✅ Partial | README documents operational procedures. Gap: No formal competency framework or training requirements. |
| A.4.4 Awareness of Responsible Use | ✔️ Implemented | Acceptable Use Policy in S3. AI disclosure footer in frontend. Mandatory `X-AI-Disclosure` response header. Model info endpoint for consumers. |
| A.4.5 Consultation | ❌ Gap | No formal stakeholder consultation process documented. |
| A.4.6 Communication About the AI System | ✔️ Implemented | `GET /v1/models/info` returns capabilities, limitations, data residency. Response headers disclose AI involvement. Frontend shows routing badges. |

---

### A.5: Assessing Impacts of AI Systems

| Control | Status | Implementation |
|---------|--------|----------------|
| A.5.2 AI System Risk Assessment | ✔️ Implemented | Risk Register in S3 with 7 identified risks (fairness, privacy, safety, reliability, accountability, inequality, third-party). Each has likelihood, impact, mitigations, owner, status. |
| A.5.3 AI System Impact Assessment | ✔️ Implemented | Impact Assessment document in S3 covering affected parties, positive/negative impacts, severity ratings, mitigations, residual risks, review schedule. |
| A.5.4 Impact Documentation | ✔️ Implemented | Versioned S3 bucket with lifecycle archival to Glacier. Point-in-time recovery enabled. |

---

### A.6: AI System Life Cycle

| Control | Status | Implementation |
|---------|--------|----------------|
| A.6.2.2 Design and Development | ✔️ Implemented | Architecture document, async processing doc, ISO gap analysis. Complexity classifier uses heuristics + model classification. |
| A.6.2.3 Training and Testing | ✅ Partial | Comprehensive test suite (26 tests). Kinesis feedback loop validates model quality. Gap: No formal bias testing protocol for the classifier. |
| A.6.2.4 Verification and Validation | ✔️ Implemented | Quality thresholds per policy, cascade pattern with confidence checks, circuit breakers for reliability. |
| A.6.2.5 Deployment | ✔️ Implemented | Two-phase Terraform deployment, AppConfig gradual rollout (linear 20% for prod), ARM64 container builds, ECR lifecycle. |
| A.6.2.6 Operation and Monitoring | ✔️ Implemented | CloudWatch dashboard (7 panels), 5 alarms, X-Ray tracing with sampling rules, Kinesis real-time events, AgentCore native OTel, provenance logging. |
| A.6.2.7 Retirement/Decommissioning | ✅ Partial | AppConfig can disable models instantly. Gap: No formal retirement procedure with notification and transition plan. |
| A.6.2.8 Responsible Integration | ✔️ Implemented | Bedrock Guardrails on all outputs. Data classification engine blocks PII from external providers. Content filtering on input and output. |
| A.6.2.9 AI System Documentation | ✔️ Implemented | Model cards index in S3. Architecture docs. README with operational procedures. Async processing documentation. |
| A.6.2.10 Defined Use and Misuse | ✔️ Implemented | Acceptable Use Policy defines intended uses and prohibited uses. Guardrails enforce topic blocks (medical, legal, financial advice). |
| A.6.2.11 Third-Party Components | ✅ Partial | External providers integrated via Gateway with credential management. Model cards document each provider. Gap: No formal onboarding evaluation checklist. |

---

### A.7: Data for AI Systems

| Control | Status | Implementation |
|---------|--------|----------------|
| A.7.2 Data for Development | ✔️ Implemented | Kinesis pipeline collects routing metrics. Weight adjuster Lambda uses data for adaptive model weights. DynamoDB stores policies and metrics. |
| A.7.3 Data Quality | ✅ Partial | Weight adjuster has learning rate bounds (MIN_WEIGHT, MAX_WEIGHT) and minimum sample thresholds. Gap: No formal data quality validation or outlier detection documented. |
| A.7.4 Data Preparation | ✔️ Implemented | Kinesis batching (100 records, 30s window), aggregation in weight adjuster, CloudWatch metric publishing. |
| A.7.5 Data Acquisition | ✔️ Implemented | Data Classification Engine scans prompts for PII (regex + Bedrock Guardrails). Blocks external routing if sensitive data detected. Data flow log records every decision. Strict guardrail for external providers blocks all PII categories. |
| A.7.6 Data Provenance | ✔️ Implemented | Full lineage record per request written to routing-audit-log table: WHO (user_id, session), WHAT (prompt hash, model, tokens), WHY (complexity, policy, candidates), HOW (strategy, async, latency, cost), WHERE (data residency, provider), MODEL PROVENANCE (provider name, family, retention policy), CONFIG STATE (AppConfig flags). 90-day retention. Accessible via Transparency API. |

---

### A.8: Information for Interested Parties (Transparency)

| Control | Status | Implementation |
|---------|--------|----------------|
| A.8.2 Informing About AI Interaction | ✔️ Implemented | Mandatory response headers (`X-AI-Model`, `X-AI-Routed`, `X-AI-Disclosure`). Frontend AI disclosure footer. `GET /v1/models/info` endpoint. |
| A.8.3 Informing About Outcomes | ✔️ Implemented | `GET /v1/routing/explain/{requestId}` returns full decision explanation: factors, scores, human-readable narrative. Routing metadata in every response body. |
| A.8.4 Access to Interaction Records | ✔️ Implemented | `GET /v1/audit/my-requests` returns user's routing history (which models served them). Scoped by authenticated user_id from JWT. |
| A.8.5 Enabling Human Actions | ✔️ Implemented | `POST /v1/concerns/report` for flagging issues. `POST /v1/admin/override` for kill switch, block/pin models. Frontend displays routing info enabling informed responses. |

---

### A.9: Use of AI Systems

| Control | Status | Implementation |
|---------|--------|----------------|
| A.9.2 Objectives for Responsible Use | ✔️ Implemented | AI Policy defines principles. Acceptable Use Policy defines expected behavior. Quality thresholds enforce minimum service levels. |
| A.9.3 Intended Use | ✔️ Implemented | Acceptable Use Policy documents intended uses (general text, code, summarization, Q&A) and prohibited uses (medical, legal, financial advice, surveillance, deepfakes). |
| A.9.4 Processes for Responsible Use | ✔️ Implemented | Bedrock Guardrails filter all content (hate, violence, sexual, misconduct, prompt attacks). Topic policy blocks prohibited domains. Word policy filters profanity. Contextual grounding reduces hallucination. |
| A.9.5 Human Oversight | ✔️ Implemented | AppConfig kill switch (system, per-provider, per-model). Admin override API. Concern reporting with SLA. Human review queue with backlog alarm. Operators can pin/block models instantly. |

---

### A.10: Third-Party and Customer Relationships

| Control | Status | Implementation |
|---------|--------|----------------|
| A.10.2 Suppliers (Model Providers) | ✅ Partial | Model cards document each provider. Strict guardrail for external routing. Kill switch per provider. Gap: No formal supplier evaluation checklist or contractual DPA template. |
| A.10.3 Shared/Pre-trained Models | ✔️ Implemented | Model cards index with provider, capabilities, limitations, data residency per model. Inference profile IDs tracked. Circuit breaker per model. |
| A.10.4 Provision to Third Parties | ✔️ Implemented | OpenAI-compatible API. Documentation (README, architecture docs). Cognito authentication. Rate limiting. Acceptable Use Policy defines customer responsibilities. |

---

## Clause-Level Assessment (Management System)

### Clause 4: Context of the Organization
✅ Partial — Architecture documents define the system context. Risk Register identifies stakeholders and external factors. Gap: No formal "AIMS scope" document with boundaries explicitly stated.

### Clause 5: Leadership
✅ Partial — AI Policy demonstrates commitment. Risk Register assigns ownership. Gap: No evidence of top management sign-off or formal role appointments.

### Clause 6: Planning
✔️ Covered — Risk Register (A.5.2), Impact Assessment (A.5.3), quality objectives embedded in routing policies (measurable thresholds).

### Clause 7: Support
✅ Partial — Infrastructure fully defined. Communication via transparency API. Documentation comprehensive. Gap: Formal competency requirements and awareness training program not documented.

### Clause 8: Operation
✔️ Covered — Terraform IaC, two-phase deployment, AppConfig change management, circuit breakers, async processing, guardrails, data classification.

### Clause 9: Performance Evaluation
✔️ Covered — CloudWatch dashboard and metrics, X-Ray tracing, Kinesis feedback loop, provenance audit trail, adaptive weight adjustment. Gap: No formal internal audit schedule or management review meeting cadence.

### Clause 10: Improvement
✔️ Mostly covered — Adaptive weight adjustment (continuous improvement), concern reporting and escalation (nonconformity handling), circuit breaker (automated corrective action). Gap: No formal corrective action procedure document.

---

## Remaining Gaps (Priority Order)

### P1 — Should Address for Certification

| # | Gap | Control | Effort |
|---|-----|---------|--------|
| 1 | Formal RACI matrix for AI governance roles | A.3.2 | Document (1 day) |
| 2 | Bias testing protocol for complexity classifier | A.6.2.3 | Process + tooling (1 week) |
| 3 | Stakeholder consultation process | A.4.5 | Document (1 day) |

### P2 — Good Practice

| # | Gap | Control | Effort |
|---|-----|---------|--------|
| 4 | Formal model retirement procedure | A.6.2.7 | Document (1 day) |
| 5 | Supplier evaluation checklist | A.10.2 | Document (1 day) |
| 6 | Competency framework for operators | A.4.3 | Document (2 days) |
| 7 | Internal audit schedule | Clause 9 | Process (1 day) |
| 8 | Corrective action procedure | Clause 10 | Document (1 day) |
| 9 | Data quality validation for feedback loop | A.7.3 | Code + document (3 days) |
| 10 | Change impact assessment template | A.3.4 | Document (1 day) |
| 11 | Formal AIMS scope statement | Clause 4 | Document (half day) |

---

## Coverage Summary

| Control Area | Total Controls | Implemented | Partial | Gap |
|---|---|---|---|---|
| A.2 Policies | 2 | 2 | 0 | 0 |
| A.3 Internal Organization | 3 | 1 | 2 | 0 |
| A.4 Resources | 5 | 3 | 1 | 1 |
| A.5 Impact Assessment | 3 | 3 | 0 | 0 |
| A.6 Lifecycle | 10 | 7 | 3 | 0 |
| A.7 Data | 5 | 4 | 1 | 0 |
| A.8 Transparency | 4 | 4 | 0 | 0 |
| A.9 Use | 4 | 4 | 0 | 0 |
| A.10 Third-Party | 3 | 2 | 1 | 0 |
| **Total** | **39** | **30** | **8** | **1** |

---

## What Was Implemented Since Initial Assessment

All items from the original "P1 — Must Address" list have been resolved:

| Original Gap | Resolution |
|---|---|
| AI Risk Assessment & Impact Assessment | Risk Register + Impact Assessment in governance S3 bucket |
| Human Oversight | Kill switch (AppConfig), override API, concern reporting (SQS/SNS), review queue |
| Data Governance for External Routing | Data Classification Engine + strict external guardrail + data flow log |
| Transparency/Disclosure | Transparency API (explain, audit, model info), mandatory headers, frontend disclosure |
| AI Policy | Formal policy document in versioned S3 |
| Content Guardrails | Bedrock Guardrails (content filter, PII, topics, words, grounding) |
| Provenance Logging | Full lineage record per request with model provenance, data residency, config state |

---

## References

- [ISO/IEC 42001:2023 — AI Management Systems](https://www.iso.org/standard/42001)
- [ISO 42001 Annex A Controls Guide](https://bastion.tech/learn/iso42001/annex-a-controls)
- [ISO 42001 Clauses 4-10](https://sprinto.com/hub/iso-42001-clauses/)
- [ISO 42001 AI Lifecycle Controls](https://certpro.com/hub/iso-42001/controls/iso-42001-ai-lifecycle/)

Content was rephrased for compliance with licensing restrictions.

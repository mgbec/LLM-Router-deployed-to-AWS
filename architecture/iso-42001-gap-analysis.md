# ISO 42001 Gap Analysis — LLM Router Architecture

## Summary

ISO/IEC 42001:2023 defines requirements for an Artificial Intelligence Management System (AIMS) across 7 mandatory clauses (4–10) and 39 Annex A controls organized into 10 areas. This analysis maps the current LLM Router design against those requirements and identifies gaps that need to be addressed for compliance.

**Current coverage**: The architecture is strong on operational controls (A.6), observability (Clause 9 partial), and third-party management (A.10 partial). It has significant gaps in governance documentation, impact assessment, data governance, transparency/explainability, and human oversight.

---

## Gap Assessment by ISO 42001 Control Area

### ✅ Partially Covered | ❌ Missing | ✔️ Adequately Covered

---

### A.2: Policies for AI

| Control | Status | Gap |
|---------|--------|-----|
| A.2.2 AI Policy | ❌ Missing | No documented AI policy exists. The design has routing *policies* (cost/latency/quality) but no organizational policy addressing responsible AI principles, ethical commitments, or compliance obligations. |
| A.2.3 Responsible AI Topics | ❌ Missing | No coverage of fairness, transparency, accountability, human oversight, or societal/environmental impact at the policy level. |

**What to add**: A formal AI Policy document covering:
- Commitment to responsible AI use (fairness, non-discrimination)
- Compliance with relevant regulations (EU AI Act, sector-specific rules)
- Ethical principles governing model selection (e.g., avoiding models trained on exploitative data)
- Environmental considerations (energy cost of routing to larger models)
- Framework for setting and reviewing AI objectives

---

### A.3: Internal Organization

| Control | Status | Gap |
|---------|--------|-----|
| A.3.2 Roles and Responsibilities | ❌ Missing | No defined roles (AIMS owner, AI system owners, data stewards, risk owners). Who approves adding a new model to the pool? Who approves routing policy changes? |
| A.3.3 Reporting AI Concerns | ❌ Missing | No mechanism for users or operators to report concerns about model outputs (harmful content, bias, quality degradation). |
| A.3.4 Impact of Organizational Changes | ❌ Missing | No process for assessing impact when models are added/removed, providers change terms, or the system's use expands. |

**What to add**:
- RACI matrix for routing policy changes, model onboarding, incident response
- A reporting channel (e.g., SNS topic or ticketing integration) for AI concerns
- Change impact assessment procedure tied to AppConfig deployment approvals

---

### A.4: Resources for AI Systems

| Control | Status | Gap |
|---------|--------|-----|
| A.4.2 Resources | ✅ Partial | Infrastructure resources are well-defined (Terraform, auto-scaling). Gap: No consideration of human resources needed for ongoing governance. |
| A.4.3 Competencies | ❌ Missing | No documentation of required competencies for operating this system (ML evaluation, bias detection, provider SLA interpretation). |
| A.4.4 Awareness of Responsible Use | ❌ Missing | No awareness materials for API consumers about responsible use of the router and its limitations. |
| A.4.5 Consultation | ❌ Missing | No stakeholder consultation process documented. |
| A.4.6 Communication About the AI System | ❌ Missing | No specification of what information is communicated to end-users about the system's behavior. |

---

### A.5: Assessing Impacts of AI Systems

| Control | Status | Gap |
|---------|--------|-----|
| A.5.2 AI System Risk Assessment | ❌ Missing | **Critical gap.** No formal risk assessment. Risks to consider: routing bias (certain topics always get cheaper models), quality degradation under budget pressure, data leakage across providers, model hallucination amplification when cascading. |
| A.5.3 AI System Impact Assessment | ❌ Missing | **Critical gap.** No assessment of impact on individuals. The router makes decisions that affect output quality for users — this needs documented impact analysis covering fairness (do all users get equal quality?) and potential harms. |
| A.5.4 Impact Documentation | ❌ Missing | No documented residual risks or mitigation decisions. |

**What to add**:
- Formal risk register covering: provider lock-in, model deprecation, bias amplification through routing, data residency violations when routing to external providers, cascade failures, cost overruns
- Impact assessment documenting who is affected when routing chooses lower-quality models (is it random? by tenant tier? — potential fairness concern if budget_conscious policies correlate with protected characteristics)
- Mitigation measures and accepted residual risk documentation

---

### A.6: AI System Life Cycle

| Control | Status | Gap |
|---------|--------|-----|
| A.6.2.2 Design and Development | ✅ Partial | Architecture is documented. Gap: No documented fairness requirements, no bias considerations in the classifier design. |
| A.6.2.3 Training and Testing | ✅ Partial | AgentCore Evaluations mentioned for benchmarking. Gap: No documented testing for bias in the complexity classifier (does it classify certain languages/dialects/topics as "simpler"?). No fairness testing across demographic groups. |
| A.6.2.4 Verification and Validation | ✅ Partial | Quality threshold and cascade pattern provide validation. Gap: No formal V&V process documented. |
| A.6.2.5 Deployment | ✔️ Covered | AppConfig gradual rollout, canary deployments, Terraform IaC. |
| A.6.2.6 Operation and Monitoring | ✔️ Covered | CloudWatch dashboard, alarms, Kinesis feedback loop, circuit breakers. |
| A.6.2.7 Retirement/Decommissioning | ❌ Missing | No process for retiring a model from the pool. What happens to routing history? How are tenants notified? |
| A.6.2.8 Responsible Integration | ✅ Partial | AgentCore provides isolation. Gap: No documented assessment of how model outputs are used downstream. |
| A.6.2.9 AI System Documentation | ✅ Partial | Architecture doc exists. Gap: Missing model cards for each model in the pool, no documented known limitations per model. |
| A.6.2.10 Defined Use and Misuse | ❌ Missing | No documentation of intended use boundaries or prohibited uses of the router. |
| A.6.2.11 Third-Party Components | ✅ Partial | External providers are integrated via Gateway. Gap: No formal assessment criteria for onboarding new models/providers. |

**What to add**:
- Model cards or datasheets for each model in the routing pool (capabilities, limitations, known biases, training data provenance)
- Bias testing protocol for the complexity classifier
- Model retirement procedure (deprecation notice period, fallback activation, data cleanup)
- Acceptable use policy defining what the router should/shouldn't be used for

---

### A.7: Data for AI Systems

| Control | Status | Gap |
|---------|--------|-----|
| A.7.2 Data for Development | ✅ Partial | Routing metrics collected for weight adjustment. Gap: No governance over what data is sent to which provider. |
| A.7.3 Data Quality | ❌ Missing | No data quality framework for the routing metrics used to adjust weights. Are the quality_score values calibrated? Who validates them? |
| A.7.4 Data Preparation | ✅ Partial | Kinesis pipeline processes events. Gap: No documented data cleaning or validation before weight adjustment. |
| A.7.5 Data Acquisition | ❌ Missing | **Important gap.** No policy on what user data (prompts, responses) flows to external providers. No data residency controls. If a prompt is routed to OpenAI, that data leaves your AWS boundary — this needs explicit governance. |
| A.7.6 Data Provenance | ❌ Missing | No tracking of where model responses came from in a way that's surfaced to the end user. Routing decisions are logged, but there's no lineage from "this response came from model X trained on data Y." |

**What to add**:
- **Data classification and residency policy**: Define which data categories (PII, regulated, confidential) can be routed to which providers. Block PII from flowing to external providers without explicit consent.
- **Data flow diagram** showing exactly what leaves your AWS account boundary
- Data quality validation for the feedback loop (outlier detection, score calibration)
- Provenance logging: record which model produced each response, make this auditable

---

### A.8: Information for Interested Parties (Transparency)

| Control | Status | Gap |
|---------|--------|-----|
| A.8.2 Informing About AI Interaction | ❌ Missing | **Critical gap.** End users are not informed they're interacting with an AI router that dynamically selects models. They may believe they're always talking to the same model. |
| A.8.3 Informing About Outcomes | ✅ Partial | The API response includes `routing.model_selected` metadata. Gap: Not mandatory; clients could ignore it. No user-facing disclosure. |
| A.8.4 Access to Interaction Records | ❌ Missing | No mechanism for end users to access their interaction history or understand which model served their request. |
| A.8.5 Enabling Human Actions | ❌ Missing | No mechanism for users to override routing decisions, request a specific model, or escalate concerns about a response. |

**What to add**:
- Mandatory disclosure header/footer informing users they're interacting with AI and that model selection is dynamic
- User-accessible audit log (which model responded to each of their requests)
- Override mechanism: allow users to pin a specific model for their session
- Feedback button: users can flag problematic responses, triggering the A.3.3 concern-reporting path

---

### A.9: Use of AI Systems

| Control | Status | Gap |
|---------|--------|-----|
| A.9.2 Objectives for Responsible Use | ❌ Missing | No documented objectives for responsible use of the router. |
| A.9.3 Intended Use | ❌ Missing | No documentation defining what the system is intended for and what it's not (e.g., "not for medical diagnosis," "not for legal advice"). |
| A.9.4 Processes for Responsible Use | ✅ Partial | Policies enforce cost/quality constraints. Gap: No processes addressing misuse detection (e.g., someone using the router to generate harmful content). |
| A.9.5 Human Oversight | ❌ Missing | **Critical gap.** No human oversight mechanism. The system routes autonomously with no human-in-the-loop or human-on-the-loop capability for high-risk decisions. No kill switch for blocking specific content categories. |

**What to add**:
- **Human oversight architecture**: Define when human review is required (e.g., sensitive topics, regulatory domains, confidence below threshold)
- Content filtering/guardrails layer (Bedrock Guardrails or custom) applied before returning responses
- Kill switch: ability for a human operator to immediately halt routing to any model or halt the entire system
- Misuse detection: flag patterns like prompt injection attempts, jailbreak patterns, high-volume automated abuse

---

### A.10: Third-Party and Customer Relationships

| Control | Status | Gap |
|---------|--------|-----|
| A.10.2 Suppliers (Model Providers) | ✅ Partial | External providers are integrated. Gap: No formal supplier assessment framework. What's the process for evaluating if a new model provider meets your responsible AI standards? |
| A.10.3 Shared/Pre-trained Models | ✅ Partial | Multiple pre-trained models are used. Gap: No documented assessment of model provenance, training data ethics, or known biases per model. |
| A.10.4 Provision to Third Parties | ❌ Missing | If this router is exposed to customers as a service, there's no documentation of what customers should know about its behavior, limitations, and their responsibilities. |

**What to add**:
- Model provider evaluation checklist (data practices, bias reports, terms of service review, data processing agreements)
- Per-model risk profile: document known failure modes, biases, and content policy differences between providers
- Customer-facing documentation if the router is offered as a service

---

## Clause-Level Gaps (Management System)

### Clause 4: Context of the Organization
❌ No documented AIMS scope, no stakeholder analysis, no analysis of internal/external issues affecting the AI system.

### Clause 5: Leadership
❌ No evidence of top management commitment, no AI policy, no defined AIMS roles.

### Clause 6: Planning
❌ No formal AI risk assessment, no AI objectives with measurable targets, no treatment plan.

### Clause 7: Support
✅ Partial — infrastructure resources are defined. ❌ Missing: competency requirements, awareness program, documented communication plan.

### Clause 8: Operation
✔️ Mostly covered — operational planning, deployment controls, change management (AppConfig, Terraform, circuit breakers) are well-addressed.

### Clause 9: Performance Evaluation
✅ Partial — CloudWatch metrics, dashboard, and feedback loop provide monitoring. ❌ Missing: formal internal audit process, management review procedure.

### Clause 10: Improvement
✅ Partial — adaptive weight adjustment is continuous improvement of routing performance. ❌ Missing: nonconformity handling procedure, corrective action process, incident management workflow.

---

## Priority Recommendations

### P1 — Must Address (Certification Blockers)

1. **AI Risk Assessment & Impact Assessment** (A.5) — Document risks to individuals and society, especially fairness implications of tiered quality by budget.
2. **Human Oversight** (A.9.5) — Add a human-in-the-loop or human-on-the-loop mechanism for sensitive routing decisions and a system-wide kill switch.
3. **Data Governance for External Routing** (A.7.5) — Establish data classification that prevents PII/sensitive data from being routed to external providers without controls.
4. **Transparency/Disclosure** (A.8.2) — Inform users that AI model selection is dynamic and which model served their request.
5. **AI Policy** (A.2.2) — Create a formal responsible AI policy that governs this system.

### P2 — Should Address (Significant Gaps)

6. **Content Guardrails** — Add a filtering layer (Bedrock Guardrails) to block harmful content regardless of which model is selected.
7. **Bias Testing for Classifier** — Validate the complexity classifier doesn't systematically disadvantage certain languages, topics, or user groups.
8. **Model Cards/Datasheets** — Document each model's capabilities, limitations, and known biases.
9. **Incident Management** — Define how routing failures, quality incidents, and harmful outputs are handled.
10. **Roles & Responsibilities** — Define AIMS owner, model governance board, incident responders.

### P3 — Should Complete (Good Practice)

11. **Model Retirement Process** — How to decommission a model from the pool safely.
12. **Supplier Assessment Framework** — Evaluation criteria for new model providers.
13. **Internal Audit Process** — Periodic review of routing fairness, cost distribution, and policy effectiveness.
14. **Acceptable Use Policy** — Define what the router is intended for and prohibited uses.
15. **Competency Framework** — Required skills for operators and administrators.

---

## Architectural Changes Recommended

To close the critical gaps, consider adding these components to the architecture:

```
┌─────────────────────────────────────────────────────────────────┐
│                    NEW COMPONENTS NEEDED                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. CONTENT GUARDRAILS LAYER (Bedrock Guardrails)               │
│     - Applied pre-routing (input) and post-routing (output)     │
│     - Blocks harmful content regardless of model                │
│     - Configurable per policy/tenant                            │
│                                                                  │
│  2. DATA CLASSIFICATION ENGINE                                   │
│     - Scans prompts for PII/sensitive data                      │
│     - Enforces data residency rules (block external routing)    │
│     - Logs data flow decisions for audit                        │
│                                                                  │
│  3. HUMAN OVERSIGHT DASHBOARD                                    │
│     - Real-time view of routing decisions                       │
│     - Manual override capability (pin model, block model)       │
│     - Alert escalation for flagged content                      │
│     - Kill switch for emergency shutdown                        │
│                                                                  │
│  4. TRANSPARENCY API                                             │
│     - /v1/routing/explain endpoint (why this model was chosen)  │
│     - Mandatory response headers (X-AI-Model, X-AI-Routed)     │
│     - User audit log (which model served each request)          │
│                                                                  │
│  5. GOVERNANCE DOCUMENTATION (S3 + versioned)                    │
│     - AI Policy                                                  │
│     - Risk Register                                              │
│     - Impact Assessment                                          │
│     - Model Cards per model in pool                             │
│     - Acceptable Use Policy                                      │
│     - Incident Response Runbook                                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## References

- [ISO/IEC 42001:2023 — AI Management Systems](https://www.iso.org/standard/42001) (standard overview)
- [ISO 42001 Annex A Controls Guide](https://bastion.tech/learn/iso42001/annex-a-controls)
- [ISO 42001 Clauses 4-10](https://sprinto.com/hub/iso-42001-clauses/)
- [ISO 42001 AI Lifecycle Controls](https://certpro.com/hub/iso-42001/controls/iso-42001-ai-lifecycle/)

Content was rephrased for compliance with licensing restrictions.

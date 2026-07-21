#!/usr/bin/env python3
"""
Generate AWS architecture diagrams for the LLM Router project.
Requires: pip install diagrams

Usage:
  python3 diagrams/generate.py

Outputs PNG files to diagrams/ directory.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import Lambda, ECS
from diagrams.aws.database import Dynamodb
from diagrams.aws.analytics import KinesisDataStreams
from diagrams.aws.integration import Appsync, SNS, SQS
from diagrams.aws.network import APIGateway
from diagrams.aws.security import Cognito, IAM
from diagrams.aws.storage import S3
from diagrams.aws.management import Cloudwatch, SystemsManager
from diagrams.aws.ml import Sagemaker
from diagrams.aws.general import User, Client
from diagrams.custom import Custom

# =============================================================================
# Diagram 1: High-Level Architecture
# =============================================================================

with Diagram(
    "LLM Router - Architecture",
    filename="diagrams/architecture",
    show=False,
    direction="TB",
    graph_attr={"fontsize": "14", "pad": "0.5"},
):
    user = User("Client\nApplications")

    with Cluster("API Layer"):
        apigw = APIGateway("API Gateway\n(HTTP API)")
        cognito = Cognito("Cognito\n(JWT Auth)")

    with Cluster("Routing Engine"):
        proxy = Lambda("API Proxy\n(sync/async dispatch)")

        with Cluster("AgentCore Runtime"):
            agent = ECS("Router Agent\n(ARM64 Container)")

        with Cluster("AgentCore Gateway (MCP)"):
            gw_classify = Lambda("classify_complexity")
            gw_data = Lambda("classify_data_sensitivity")
            gw_feedback = Lambda("record_feedback")

    with Cluster("Async Processing"):
        async_lambda = Lambda("Async Processor\n(15 min timeout)")
        async_db = Dynamodb("Async Requests")

    with Cluster("Model Pool (Bedrock)"):
        nova_lite = Sagemaker("Nova Lite\n(Simple)")
        nova_pro = Sagemaker("Nova Pro\n(Moderate)")
        sonnet = Sagemaker("Sonnet 4.6\n(Moderate/Complex)")
        opus = Sagemaker("Opus 4.6\n(Complex - Async)")

    with Cluster("Observability & Feedback"):
        kinesis = KinesisDataStreams("Routing Events")
        weight_adj = Lambda("Weight Adjuster")
        cloudwatch = Cloudwatch("CloudWatch\nDashboard + Alarms")

    with Cluster("Data Stores"):
        policies_db = Dynamodb("Routing Policies")
        metrics_db = Dynamodb("Routing Metrics")
        audit_db = Dynamodb("Audit Log\n(Provenance)")
        flow_db = Dynamodb("Data Flow Log")

    with Cluster("Configuration"):
        appconfig = SystemsManager("AppConfig\n(Hot-Swap)")

    # Request flow
    user >> apigw
    apigw >> cognito
    apigw >> proxy

    # Sync path
    proxy >> agent
    agent >> gw_classify
    agent >> gw_data
    agent >> gw_feedback

    # Model invocation
    agent >> Edge(label="simple") >> nova_lite
    agent >> Edge(label="moderate") >> nova_pro
    agent >> Edge(label="moderate") >> sonnet

    # Async path
    proxy >> Edge(label="complex\n(auto-detect)", style="dashed") >> async_lambda
    async_lambda >> agent
    async_lambda >> async_db
    async_lambda >> opus

    # Feedback loop
    agent >> kinesis
    kinesis >> weight_adj
    weight_adj >> metrics_db
    weight_adj >> cloudwatch

    # Config reads
    agent >> appconfig
    agent >> policies_db
    agent >> audit_db


# =============================================================================
# Diagram 2: Data Flow
# =============================================================================

with Diagram(
    "LLM Router - Data Flow",
    filename="diagrams/dataflow",
    show=False,
    direction="LR",
    graph_attr={"fontsize": "13", "pad": "0.5"},
):
    client = Client("Client")

    with Cluster("Ingress"):
        apigw = APIGateway("API Gateway")
        auth = Cognito("JWT Validation")

    with Cluster("Processing"):
        proxy = Lambda("API Proxy")
        runtime = ECS("Router Agent")

    with Cluster("Gateway Tools (MCP)"):
        classify = Lambda("Classify\nComplexity")
        data_check = Lambda("Data\nClassification")
        feedback = Lambda("Record\nFeedback")

    with Cluster("Models"):
        bedrock = Sagemaker("Bedrock\n(Nova/Sonnet/Opus)")

    with Cluster("Audit & Compliance"):
        audit = Dynamodb("Audit Log\n(Provenance)")
        flow_log = Dynamodb("Data Flow\nLog")
        governance = S3("Governance\nDocs")

    with Cluster("Metrics Pipeline"):
        kinesis = KinesisDataStreams("Kinesis")
        adjuster = Lambda("Weight\nAdjuster")
        cw = Cloudwatch("CloudWatch")

    with Cluster("Human Oversight"):
        concerns = SQS("Concerns\nQueue")
        alerts = SNS("Escalation\nAlerts")

    # Flow
    client >> apigw >> auth >> proxy >> runtime
    runtime >> classify
    runtime >> data_check
    runtime >> bedrock
    runtime >> feedback
    runtime >> kinesis >> adjuster >> cw

    # Audit writes
    runtime >> audit
    data_check >> flow_log

    # Human oversight
    proxy >> concerns >> alerts


# =============================================================================
# Diagram 3: ISO 42001 Compliance Components
# =============================================================================

with Diagram(
    "LLM Router - ISO 42001 Compliance",
    filename="diagrams/iso42001",
    show=False,
    direction="TB",
    graph_attr={"fontsize": "13", "pad": "0.5"},
):
    with Cluster("A.2 Policies"):
        policy_s3 = S3("AI Policy\nAcceptable Use")

    with Cluster("A.5 Impact Assessment"):
        risk_s3 = S3("Risk Register\nImpact Assessment")

    with Cluster("A.7 Data Governance"):
        guardrails = Lambda("Bedrock\nGuardrails")
        data_class = Lambda("Data\nClassifier")
        flow_log = Dynamodb("Data Flow\nLog")
        provenance = Dynamodb("Provenance\nAudit Log")

    with Cluster("A.8 Transparency"):
        explain = Lambda("Explain API")
        audit_api = Lambda("User Audit\nLog API")
        models_api = Lambda("Model\nInfo API")

    with Cluster("A.9 Human Oversight"):
        kill_switch = SystemsManager("Kill Switch\n(AppConfig)")
        override = Lambda("Admin\nOverride API")
        concerns = SQS("Concerns\nQueue")
        review = Dynamodb("Review\nQueue")

    with Cluster("A.10 Third-Party"):
        model_cards = S3("Model Cards")
        ext_guardrail = Lambda("External\nRouting Guardrail")

    with Cluster("Clause 9 Audit"):
        auditor = IAM("Auditor Role\n(Read-Only)")

    # Connections
    guardrails >> flow_log
    data_class >> flow_log
    auditor >> provenance
    auditor >> flow_log
    auditor >> policy_s3
    auditor >> risk_s3
    concerns >> review


print("✓ Diagrams generated:")
print("  - diagrams/architecture.png")
print("  - diagrams/dataflow.png")
print("  - diagrams/iso42001.png")

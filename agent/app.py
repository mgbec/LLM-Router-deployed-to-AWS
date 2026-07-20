"""
LLM Router Agent - AgentCore Runtime Entry Point
Implements dynamic model selection and provider switching.
"""

import json
import os
import time
import logging
from typing import Any

# =============================================================================
# OpenTelemetry Instrumentation
# Must be initialized BEFORE boto3 clients are created
# =============================================================================

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource

# AgentCore sets OTEL_EXPORTER_OTLP_ENDPOINT automatically
# If not set, traces go nowhere (safe fallback)
OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")

resource = Resource.create({
    "service.name": "llm-router-agent",
    "service.version": "1.0.0",
    "deployment.environment": os.environ.get("ENVIRONMENT", "dev"),
})

provider = TracerProvider(resource=resource)

if OTEL_ENDPOINT:
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    exporter = OTLPSpanExporter(endpoint=f"{OTEL_ENDPOINT}/v1/traces")
    provider.add_span_processor(BatchSpanProcessor(exporter))

trace.set_tracer_provider(provider)
tracer = trace.get_tracer("llm-router")

# Instrument botocore (covers all boto3 clients: bedrock, dynamodb, kinesis, etc.)
from opentelemetry.instrumentation.botocore import BotocoreInstrumentor
BotocoreInstrumentor().instrument()

# Instrument FastAPI (covers incoming HTTP requests)
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

import boto3

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration from environment
REGION = os.environ.get("REGION", "us-east-1")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
CLASSIFIER_MODEL_ID = os.environ.get("CLASSIFIER_MODEL_ID", "us.amazon.nova-lite-v1:0")
DEFAULT_FALLBACK_MODEL = os.environ.get("DEFAULT_FALLBACK_MODEL", "us.anthropic.claude-sonnet-4-6")
POLICY_TABLE = os.environ.get("ROUTING_POLICY_TABLE", "")
METRICS_TABLE = os.environ.get("ROUTING_METRICS_TABLE", "")
KINESIS_STREAM = os.environ.get("KINESIS_STREAM_NAME", "")
APPCONFIG_APP_ID = os.environ.get("APPCONFIG_APP_ID", "")
APPCONFIG_ENV_ID = os.environ.get("APPCONFIG_ENV_ID", "")
APPCONFIG_PROFILE_ID = os.environ.get("APPCONFIG_PROFILE_ID", "")
ENABLE_EXTERNAL = os.environ.get("ENABLE_EXTERNAL_PROVIDERS", "false").lower() == "true"
GUARDRAIL_ID = os.environ.get("GUARDRAIL_ID", "")
GUARDRAIL_VERSION = os.environ.get("GUARDRAIL_VERSION", "DRAFT")
AUDIT_LOG_TABLE = os.environ.get("AUDIT_LOG_TABLE", "")
KILL_SWITCH_PROFILE = os.environ.get("KILL_SWITCH_PROFILE", "")
GATEWAY_URL = os.environ.get("GATEWAY_URL", "")

# AWS clients
bedrock = boto3.client("bedrock-runtime", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)
kinesis = boto3.client("kinesis", region_name=REGION)
appconfig_client = boto3.client("appconfigdata", region_name=REGION)
cloudwatch = boto3.client("cloudwatch", region_name=REGION)

# Tables
policy_table = dynamodb.Table(POLICY_TABLE) if POLICY_TABLE else None


# =============================================================================
# AgentCore Gateway Client (MCP Tool Invocation)
# =============================================================================

class GatewayClient:
    """
    Calls tools registered on the AgentCore Gateway via MCP protocol.
    This routes tool calls through the gateway for centralized observability,
    auth, and tool discovery.
    """

    def __init__(self, gateway_url: str, region: str):
        self.gateway_url = gateway_url
        self.region = region
        self._session = boto3.Session()
        self._credentials = None

    def _get_signed_headers(self, method: str, url: str, body: bytes) -> dict:
        """Sign request with SigV4 for gateway IAM auth."""
        from botocore.auth import SigV4Auth
        from botocore.awsrequest import AWSRequest

        credentials = self._session.get_credentials().get_frozen_credentials()
        request = AWSRequest(method=method, url=url, data=body, headers={
            "Content-Type": "application/json",
        })
        SigV4Auth(credentials, "bedrock-agentcore", self.region).add_auth(request)
        return dict(request.headers)

    def call_tool(self, tool_name: str, arguments: dict) -> dict:
        """
        Invoke a tool via the AgentCore Gateway MCP endpoint.
        Returns the tool result or raises an exception.
        """
        if not self.gateway_url:
            logger.warning("Gateway URL not configured, skipping gateway call")
            return {"error": "gateway not configured"}

        import urllib.request
        import urllib.error

        # MCP tools/call request format
        mcp_request = {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {
                "name": tool_name,
                "arguments": arguments,
            },
            "id": f"req-{int(time.time()*1000)}",
        }

        body = json.dumps(mcp_request).encode("utf-8")
        url = f"{self.gateway_url}/mcp"

        try:
            headers = self._get_signed_headers("POST", url, body)
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=30) as resp:
                result = json.loads(resp.read())
                # MCP response format
                if "result" in result:
                    content = result["result"].get("content", [])
                    if content and isinstance(content, list):
                        text = content[0].get("text", "")
                        try:
                            return json.loads(text)
                        except json.JSONDecodeError:
                            return {"raw": text}
                    return result["result"]
                elif "error" in result:
                    logger.warning(f"Gateway tool error: {result['error']}")
                    return {"error": result["error"]}
                return result
        except urllib.error.HTTPError as e:
            logger.warning(f"Gateway HTTP error calling {tool_name}: {e.code} {e.reason}")
            return {"error": f"HTTP {e.code}: {e.reason}"}
        except Exception as e:
            logger.warning(f"Gateway call failed for {tool_name}: {e}")
            return {"error": str(e)}


# Initialize gateway client
gateway = GatewayClient(GATEWAY_URL, REGION)

# Model cost table (per 1K input tokens)
MODEL_COSTS = {
    "us.amazon.nova-lite-v1:0": 0.00006,
    "us.amazon.nova-pro-v1:0": 0.0008,
    "us.anthropic.claude-haiku-4-5-20251001-v1:0": 0.0008,
    "us.anthropic.claude-sonnet-4-6": 0.003,
    "us.anthropic.claude-opus-4-6-v1": 0.015,
    "us.meta.llama4-maverick-17b-instruct-v1:0": 0.0002,
}

# Static model tier mapping (used as fallback if AppConfig unavailable)
DEFAULT_MODEL_TIERS = {
    "simple": [
        "us.amazon.nova-lite-v1:0",
    ],
    "moderate": [
        "us.amazon.nova-pro-v1:0",
        "us.anthropic.claude-sonnet-4-6",
    ],
    "complex": [
        "us.anthropic.claude-opus-4-6-v1",
        "us.anthropic.claude-sonnet-4-6",
    ],
    "specialized": [
        "us.anthropic.claude-sonnet-4-6",
    ],
}

# Circuit breaker state
circuit_breakers: dict[str, dict] = {}
FAILURE_THRESHOLD = 3
RECOVERY_TIMEOUT_S = 60


# =============================================================================
# AppConfig Hot-Swap Integration
# =============================================================================

class AppConfigManager:
    """
    Manages live configuration from AWS AppConfig.
    Polls for updates with caching to avoid per-request latency.
    """

    def __init__(self):
        self._routing_token = None
        self._kill_switch_token = None
        self._routing_config = None
        self._kill_switch_config = None
        self._last_fetch = 0
        self._cache_ttl_seconds = 30  # Poll every 30 seconds

    def _start_session(self, profile_id: str) -> str:
        """Start a configuration session and return the initial token."""
        try:
            response = appconfig_client.start_configuration_session(
                ApplicationIdentifier=APPCONFIG_APP_ID,
                EnvironmentIdentifier=APPCONFIG_ENV_ID,
                ConfigurationProfileIdentifier=profile_id,
                RequiredMinimumPollIntervalInSeconds=15
            )
            return response["InitialConfigurationToken"]
        except Exception as e:
            logger.warning(f"Failed to start AppConfig session for {profile_id}: {e}")
            return None

    def _fetch_config(self, token: str) -> tuple:
        """Fetch latest config using the token. Returns (config_dict, next_token)."""
        try:
            response = appconfig_client.get_latest_configuration(
                ConfigurationToken=token
            )
            next_token = response["NextPollConfigurationToken"]
            content = response["Configuration"].read()
            if content:
                config = json.loads(content)
                return config, next_token
            # Empty content means no change since last poll
            return None, next_token
        except Exception as e:
            logger.warning(f"Failed to fetch AppConfig: {e}")
            return None, None

    def get_routing_config(self) -> dict:
        """Get current routing feature flags."""
        now = time.time()

        # Return cached if fresh
        if self._routing_config and (now - self._last_fetch) < self._cache_ttl_seconds:
            return self._routing_config

        # Initialize session if needed
        if not self._routing_token and APPCONFIG_PROFILE_ID:
            self._routing_token = self._start_session(APPCONFIG_PROFILE_ID)

        # Fetch latest
        if self._routing_token:
            config, next_token = self._fetch_config(self._routing_token)
            if config:
                self._routing_config = config
            if next_token:
                self._routing_token = next_token
            self._last_fetch = now

        return self._routing_config or {}

    def get_kill_switch_config(self) -> dict:
        """Get current kill switch feature flags."""
        if not self._kill_switch_token and KILL_SWITCH_PROFILE:
            self._kill_switch_token = self._start_session(KILL_SWITCH_PROFILE)

        if self._kill_switch_token:
            config, next_token = self._fetch_config(self._kill_switch_token)
            if config:
                self._kill_switch_config = config
            if next_token:
                self._kill_switch_token = next_token

        return self._kill_switch_config or {}

    def is_system_active(self) -> bool:
        """Check if the system kill switch is engaged."""
        config = self.get_kill_switch_config()
        values = config.get("values", {})
        return values.get("system_active", {}).get("enabled", True)

    def is_model_enabled(self, model_id: str) -> bool:
        """Check if a specific model is enabled via feature flags."""
        config = self.get_routing_config()
        values = config.get("values", {})

        # Map model IDs to feature flag names
        model_flag_map = {
            "us.amazon.nova-lite-v1:0": "enable_nova_lite",
            "us.amazon.nova-pro-v1:0": "enable_nova_pro",
            "us.anthropic.claude-sonnet-4-6": "enable_claude_sonnet",
            "us.anthropic.claude-opus-4-6-v1": "enable_claude_opus",
        }

        flag_name = model_flag_map.get(model_id)
        if flag_name:
            return values.get(flag_name, {}).get("enabled", True)
        return True  # Unknown models default to enabled

    def get_cascade_config(self) -> dict:
        """Get cascade/escalation configuration."""
        config = self.get_routing_config()
        values = config.get("values", {})
        return values.get("cascade_enabled", {"enabled": True, "confidence_threshold": 0.75})

    def get_circuit_breaker_config(self) -> dict:
        """Get circuit breaker thresholds."""
        config = self.get_routing_config()
        values = config.get("values", {})
        return values.get("circuit_breaker", {"failure_threshold": 3, "recovery_timeout_secs": 60})

    def get_active_model_tiers(self) -> dict:
        """Build model tiers filtered by enabled flags."""
        tiers = {}
        for tier_name, models in DEFAULT_MODEL_TIERS.items():
            enabled_models = [m for m in models if self.is_model_enabled(m)]
            tiers[tier_name] = enabled_models if enabled_models else [DEFAULT_FALLBACK_MODEL]
        return tiers


# Global AppConfig manager instance
config_manager = AppConfigManager()


# =============================================================================
# Routing Tools
# =============================================================================

def classify_complexity(prompt: str) -> dict:
    """Classify the complexity of a user prompt using a fast, cheap model."""
    # Quick heuristic for obvious cases
    quick = _quick_classify(prompt)
    if quick:
        return {"complexity": quick, "method": "heuristic", "latency_ms": 0}

    start = time.time()

    classification_prompt = f"""Classify this prompt's complexity as exactly one of: simple, moderate, complex, specialized.
    
Respond with ONLY the classification word.

Prompt: {prompt[:2000]}

Classification:"""

    response = bedrock.converse(
        modelId=CLASSIFIER_MODEL_ID,
        messages=[{"role": "user", "content": [{"text": classification_prompt}]}],
        inferenceConfig={"maxTokens": 10, "temperature": 0.0}
    )

    output = response["output"]["message"]["content"][0]["text"].strip().lower()
    valid = {"simple", "moderate", "complex", "specialized"}
    complexity = output if output in valid else "moderate"

    latency = (time.time() - start) * 1000
    return {"complexity": complexity, "method": "model", "latency_ms": round(latency, 1)}


def select_model(complexity: str, policy_id: str = "default", max_cost: float = None) -> dict:
    """Select the optimal model based on complexity, policy, and constraints."""
    # Load policy
    policy = _load_policy(policy_id)

    # Get candidate models for this complexity tier
    candidates = MODEL_TIERS.get(complexity, MODEL_TIERS["moderate"])

    # Filter by circuit breaker status
    available = [m for m in candidates if _is_available(m)]
    if not available:
        # Fallback chain
        fallback_chain = policy.get("fallback_chain", [DEFAULT_FALLBACK_MODEL])
        available = [m for m in fallback_chain if _is_available(m)]
        if not available:
            available = [DEFAULT_FALLBACK_MODEL]

    # Apply cost constraint
    budget = max_cost or policy.get("max_cost_per_request", 0.05)
    affordable = [m for m in available if MODEL_COSTS.get(m, 0.01) <= budget]
    if not affordable:
        affordable = available[:1]  # Take cheapest available

    # Score candidates (lower cost + higher weight = better)
    weights = policy.get("model_weights", {})
    scored = []
    for model in affordable:
        cost = MODEL_COSTS.get(model, 0.01)
        weight = float(weights.get(model, {}).get("weight", 1.0))
        score = weight / (cost + 0.0001)  # Higher weight, lower cost = better
        scored.append((model, score, cost))

    scored.sort(key=lambda x: x[1], reverse=True)
    selected = scored[0]

    return {
        "model_id": selected[0],
        "provider": "bedrock",
        "estimated_cost": selected[2],
        "reason": f"Selected for {complexity} complexity (score: {selected[1]:.2f})"
    }


def invoke_selected_model(model_id: str, messages: list, parameters: dict = None) -> dict:
    """Invoke the selected model and return the response."""
    params = parameters or {}
    start = time.time()

    try:
        # Format messages for Bedrock Converse API
        bedrock_messages = []
        system_prompts = []
        for msg in messages:
            if msg.get("role") == "system":
                system_prompts.append({"text": msg["content"]})
            else:
                bedrock_messages.append({
                    "role": msg["role"],
                    "content": [{"text": msg["content"]}]
                })

        request = {
            "modelId": model_id,
            "messages": bedrock_messages,
            "inferenceConfig": {
                "maxTokens": params.get("max_tokens", 4096),
                "temperature": params.get("temperature", 0.7),
            }
        }
        if system_prompts:
            request["system"] = system_prompts

        response = bedrock.converse(**request)

        output = response["output"]["message"]["content"][0]["text"]
        usage = response.get("usage", {})
        latency = (time.time() - start) * 1000

        # Record success
        _record_success(model_id)

        return {
            "response": output,
            "model_id": model_id,
            "provider": "bedrock",
            "latency_ms": round(latency, 2),
            "input_tokens": usage.get("inputTokens", 0),
            "output_tokens": usage.get("outputTokens", 0),
            "stop_reason": response.get("stopReason", "end_turn"),
            "error": False
        }

    except Exception as e:
        latency = (time.time() - start) * 1000
        _record_failure(model_id)
        logger.error(f"Model invocation failed for {model_id}: {e}")
        return {
            "response": None,
            "model_id": model_id,
            "provider": "bedrock",
            "latency_ms": round(latency, 2),
            "error": True,
            "error_message": str(e)
        }


def emit_routing_event(event_data: dict) -> dict:
    """Emit a routing event to Kinesis for async processing."""
    if not KINESIS_STREAM:
        return {"status": "skipped", "reason": "no stream configured"}

    try:
        kinesis.put_record(
            StreamName=KINESIS_STREAM,
            Data=json.dumps(event_data).encode("utf-8"),
            PartitionKey=event_data.get("model_id", "default")
        )
        return {"status": "emitted"}
    except Exception as e:
        logger.warning(f"Failed to emit routing event: {e}")
        return {"status": "failed", "error": str(e)}


# =============================================================================
# Helper Functions
# =============================================================================

def _quick_classify(prompt: str) -> str | None:
    """Fast heuristic classification."""
    words = prompt.split()
    if len(words) <= 5:
        lower = prompt.lower().strip()
        greetings = {"hi", "hello", "hey", "thanks", "thank you", "bye"}
        if any(lower.startswith(g) for g in greetings):
            return "simple"
    if len(words) <= 3:
        return "simple"
    return None


def _load_policy(policy_id: str) -> dict:
    """Load routing policy from DynamoDB."""
    if not policy_table:
        return _default_policy()

    try:
        response = policy_table.get_item(Key={"policy_id": policy_id})
        item = response.get("Item")
        if item and "config" in item:
            return item["config"]
    except Exception as e:
        logger.warning(f"Failed to load policy {policy_id}: {e}")

    return _default_policy()


def _default_policy() -> dict:
    return {
        "max_cost_per_request": 0.05,
        "max_latency_ms": 3000,
        "quality_threshold": 0.8,
        "fallback_chain": [DEFAULT_FALLBACK_MODEL, "us.amazon.nova-pro-v1:0", "us.amazon.nova-lite-v1:0"],
        "model_weights": {}
    }


def _is_available(model_id: str) -> bool:
    """Check if a model is available (circuit breaker not open)."""
    cb = circuit_breakers.get(model_id, {})
    if cb.get("state") == "open":
        if time.time() > cb.get("recovery_at", 0):
            cb["state"] = "half-open"
            return True
        return False
    return True


def _record_success(model_id: str):
    """Record successful invocation for circuit breaker."""
    if model_id in circuit_breakers:
        circuit_breakers[model_id] = {"state": "closed", "failures": 0}


def _record_failure(model_id: str):
    """Record failed invocation for circuit breaker."""
    cb_config = config_manager.get_circuit_breaker_config()
    threshold = int(cb_config.get("failure_threshold", FAILURE_THRESHOLD))
    timeout = int(cb_config.get("recovery_timeout_secs", RECOVERY_TIMEOUT_S))

    cb = circuit_breakers.setdefault(model_id, {"state": "closed", "failures": 0})
    cb["failures"] = cb.get("failures", 0) + 1
    if cb["failures"] >= threshold:
        cb["state"] = "open"
        cb["recovery_at"] = time.time() + timeout
        logger.warning(f"Circuit breaker OPEN for {model_id} (failures: {cb['failures']}, threshold: {threshold})")


# =============================================================================
# Provenance Logging (ISO 42001 A.7.6)
# =============================================================================

# DynamoDB table for audit log
_audit_table = None

def _get_audit_table():
    """Lazy-init the audit log table."""
    global _audit_table
    if _audit_table is None and AUDIT_LOG_TABLE:
        _audit_table = dynamodb.Table(AUDIT_LOG_TABLE)
    return _audit_table


def _write_provenance(
    request_id: str,
    user_id: str,
    session_id: str,
    prompt: str,
    model_id: str,
    provider: str,
    complexity: str,
    classification_method: str,
    policy_id: str,
    candidates_considered: list,
    latency_ms: float,
    input_tokens: int,
    output_tokens: int,
    cost: float,
    escalated: bool,
    is_async: bool,
):
    """
    Write a full provenance/lineage record for each routing decision.
    ISO 42001 A.7.6: Data Provenance — track origin and history of AI outputs.

    Records:
    - WHO: user_id, session_id
    - WHAT: prompt hash, model selected, response metadata
    - WHY: complexity classification, policy applied, candidates scored
    - HOW: classification method, selection algorithm, cost/quality factors
    - WHEN: timestamp, latency
    - WHERE: provider, region, data residency status
    """
    table = _get_audit_table()
    if not table:
        return

    now = int(time.time())
    import hashlib
    prompt_hash = hashlib.sha256(prompt.encode()).hexdigest()[:16] if prompt else ""

    try:
        from decimal import Decimal
        table.put_item(Item={
            # Identity
            "request_id": request_id,
            "timestamp": now,
            "user_id": user_id or "anonymous",
            "session_id": session_id or "none",

            # Data Lineage - WHAT was produced
            "prompt_hash": prompt_hash,
            "prompt_length": len(prompt),
            "model_id": model_id,
            "provider": provider,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,

            # Data Lineage - WHY this model was chosen
            "complexity": complexity,
            "classification_method": classification_method,
            "policy_id": policy_id,
            "candidates_considered": candidates_considered,
            "model_scores": {m: str(MODEL_COSTS.get(m, "unknown")) for m in candidates_considered},

            # Data Lineage - HOW it was processed
            "routing_strategy": "complexity_based",
            "is_async": is_async,
            "escalated": escalated,
            "latency_ms": Decimal(str(round(latency_ms, 2))),
            "estimated_cost": Decimal(str(cost)),

            # Data Residency - WHERE data flowed
            "data_residency": "aws-us-east-1" if "us." in model_id else "unknown",
            "external_provider": provider != "bedrock",
            "pii_detected": False,  # Would be True if data classifier flagged it

            # Model Provenance - WHO made the model
            "model_provenance": {
                "provider_name": _get_model_provider(model_id),
                "model_family": _get_model_family(model_id),
                "inference_profile": model_id,
                "data_retention": "none (Bedrock does not retain prompts)",
            },

            # AppConfig state at time of decision
            "appconfig_state": {
                "system_active": config_manager.is_system_active(),
                "model_enabled": config_manager.is_model_enabled(model_id),
            },

            # TTL
            "expires_at": now + (90 * 24 * 3600),  # 90-day retention
        })
    except Exception as e:
        logger.warning(f"Failed to write provenance record: {e}")


def _get_model_provider(model_id: str) -> str:
    """Map model ID to provider name."""
    if "anthropic" in model_id:
        return "Anthropic"
    elif "amazon" in model_id or "nova" in model_id:
        return "Amazon"
    elif "meta" in model_id or "llama" in model_id:
        return "Meta"
    elif "mistral" in model_id:
        return "Mistral AI"
    return "Unknown"


def _get_model_family(model_id: str) -> str:
    """Map model ID to model family."""
    if "opus" in model_id:
        return "Claude Opus"
    elif "sonnet" in model_id:
        return "Claude Sonnet"
    elif "haiku" in model_id:
        return "Claude Haiku"
    elif "nova-lite" in model_id:
        return "Nova Lite"
    elif "nova-pro" in model_id:
        return "Nova Pro"
    elif "llama" in model_id:
        return "Llama"
    elif "mistral" in model_id:
        return "Mistral"
    return "Unknown"


# =============================================================================
# HTTP Server (AgentCore Runtime expects HTTP on port 8080)
# =============================================================================

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
import uvicorn

app = FastAPI(title="LLM Router Agent")

# Instrument FastAPI for incoming request tracing
FastAPIInstrumentor.instrument_app(app)


@app.post("/invocations")
@app.post("/invoke")
async def invoke(request: Request):
    """Main invocation endpoint for AgentCore Runtime."""
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(
            status_code=400,
            content={"error": "Invalid JSON in request body"}
        )
    
    prompt = body.get("prompt", "")
    messages = body.get("messages", [])
    routing_hints = body.get("routing", {})
    request_id = body.get("request_id", "")

    if not prompt and messages:
        prompt = messages[-1].get("content", "")

    try:
        # Step 1: Classify complexity (via Gateway tool or direct fallback)
        with tracer.start_as_current_span("classify_complexity") as span:
            complexity = _quick_classify(prompt)
            classification_method = "heuristic"
            
            if not complexity:
                # Try gateway tool first (for observability)
                try:
                    gw_result = gateway.call_tool("classify_complexity", {"prompt": prompt[:2000]})
                    if "error" not in gw_result and "complexity" in gw_result:
                        complexity = gw_result["complexity"]
                        classification_method = "gateway"
                    else:
                        raise ValueError(gw_result.get("error", "no complexity in response"))
                except Exception as gw_err:
                    # Fallback: call Bedrock directly
                    logger.info(f"Gateway classify fallback (reason: {gw_err})")
                    try:
                        classification_prompt = f"Classify this prompt's complexity as exactly one of: simple, moderate, complex, specialized. Respond with ONLY the word.\n\nPrompt: {prompt[:2000]}\n\nClassification:"
                        cls_response = bedrock.converse(
                            modelId=CLASSIFIER_MODEL_ID,
                            messages=[{"role": "user", "content": [{"text": classification_prompt}]}],
                            inferenceConfig={"maxTokens": 10, "temperature": 0.0}
                        )
                        raw = cls_response["output"]["message"]["content"][0]["text"].strip().lower()
                        valid = {"simple", "moderate", "complex", "specialized"}
                        complexity = raw if raw in valid else "moderate"
                        classification_method = "model_direct"
                    except Exception as cls_err:
                        logger.warning(f"Classification failed: {cls_err}, defaulting to moderate")
                        complexity = "moderate"
                        classification_method = "fallback"

            span.set_attribute("routing.complexity", complexity)
            span.set_attribute("routing.classification_method", classification_method)

        # Step 2: Check kill switch
        if not config_manager.is_system_active():
            return JSONResponse(content={
                "content": "System is currently disabled by operator. Please try again later.",
                "model_id": None,
                "provider": None,
                "complexity": complexity,
                "system_disabled": True,
                "request_id": request_id
            })

        # Step 3: Select model based on complexity and policy
        policy_id = routing_hints.get("policy", "default")
        policy = _load_policy(policy_id)
        max_cost = routing_hints.get("max_cost") or policy.get("max_cost_per_request", 0.05)
        is_async = routing_hints.get("async", False)
        
        # Get model tiers filtered by AppConfig enabled flags
        active_tiers = config_manager.get_active_model_tiers()
        candidates = active_tiers.get(complexity, active_tiers.get("moderate", [DEFAULT_FALLBACK_MODEL]))
        
        # For sync requests, skip slow models (Opus) to avoid API Gateway timeout
        if not is_async:
            fast_models = [m for m in candidates if "opus" not in m]
            if fast_models:
                candidates = fast_models
        
        available = [m for m in candidates if _is_available(m)]
        if not available:
            available = [DEFAULT_FALLBACK_MODEL]
        
        # Filter by cost
        affordable = [m for m in available if MODEL_COSTS.get(m, 0.01) <= max_cost]
        if not affordable:
            affordable = available[:1]
        
        selected_model = affordable[0]

        # Step 4: Data classification check via Gateway (for external providers)
        if "external" in selected_model or ENABLE_EXTERNAL:
            try:
                dc_result = gateway.call_tool("classify_data_sensitivity", {
                    "prompt": prompt[:2000],
                    "target_provider": "external",
                    "request_id": request_id,
                })
                if dc_result.get("routing_allowed") is False:
                    # PII detected, force internal model
                    logger.info(f"Data classification blocked external routing: {dc_result.get('reason')}")
                    selected_model = DEFAULT_FALLBACK_MODEL
            except Exception as dc_err:
                logger.warning(f"Data classification gateway call failed: {dc_err}")

        # Step 5: Invoke the selected model
        with tracer.start_as_current_span("invoke_model") as span:
            span.set_attribute("model.id", selected_model)
            span.set_attribute("model.provider", "bedrock")
            span.set_attribute("routing.complexity", complexity)
            span.set_attribute("routing.policy", policy_id)

            start_time = time.time()
            
            bedrock_messages = []
            system_prompts = []
            for msg in messages:
                if msg.get("role") == "system":
                    system_prompts.append({"text": msg["content"]})
                else:
                    bedrock_messages.append({
                        "role": msg["role"],
                        "content": [{"text": msg["content"]}]
                    })
            
            if not bedrock_messages:
                bedrock_messages = [{"role": "user", "content": [{"text": prompt}]}]

            # Limit tokens for sync requests to avoid timeouts
            # Complex/Opus can use more tokens in async mode
            max_tokens = 2048 if complexity in ("complex", "specialized") else 4096

            invoke_params = {
                "modelId": selected_model,
                "messages": bedrock_messages,
                "inferenceConfig": {"maxTokens": max_tokens, "temperature": 0.7}
            }
            if system_prompts:
                invoke_params["system"] = system_prompts

            response = bedrock.converse(**invoke_params)
            
            output_text = response["output"]["message"]["content"][0]["text"]
            usage = response.get("usage", {})
            latency_ms = (time.time() - start_time) * 1000

            span.set_attribute("model.latency_ms", round(latency_ms, 2))
            span.set_attribute("model.input_tokens", usage.get("inputTokens", 0))
            span.set_attribute("model.output_tokens", usage.get("outputTokens", 0))

            _record_success(selected_model)

        # Step 6: Emit routing event (async, non-blocking)
        try:
            if KINESIS_STREAM:
                kinesis.put_record(
                    StreamName=KINESIS_STREAM,
                    Data=json.dumps({
                        "request_id": request_id,
                        "model_id": selected_model,
                        "complexity": complexity,
                        "latency_ms": round(latency_ms, 2),
                        "policy_id": policy_id,
                        "cost": MODEL_COSTS.get(selected_model, 0),
                    }).encode("utf-8"),
                    PartitionKey=selected_model
                )
        except Exception:
            pass  # Non-critical

        # Step 7: Record feedback via Gateway (non-blocking)
        try:
            gateway.call_tool("record_feedback", {
                "request_id": request_id,
                "model_id": selected_model,
                "latency_ms": round(latency_ms, 2),
                "quality_score": 0.0,  # Will be updated by user feedback later
                "cost": MODEL_COSTS.get(selected_model, 0),
                "escalated": False,
            })
        except Exception:
            pass  # Non-critical

        # Step 8: Write provenance record to audit log (ISO 42001 A.7.6)
        _write_provenance(
            request_id=request_id,
            user_id=body.get("user_id", ""),
            session_id=body.get("session_id", ""),
            prompt=prompt,
            model_id=selected_model,
            provider="bedrock",
            complexity=complexity,
            classification_method=classification_method,
            policy_id=policy_id,
            candidates_considered=candidates,
            latency_ms=round(latency_ms, 2),
            input_tokens=usage.get("inputTokens", 0),
            output_tokens=usage.get("outputTokens", 0),
            cost=MODEL_COSTS.get(selected_model, 0),
            escalated=False,
            is_async=False,
        )

        return JSONResponse(content={
            "content": output_text,
            "model_id": selected_model,
            "provider": "bedrock",
            "complexity": complexity,
            "classification_method": classification_method,
            "latency_ms": round(latency_ms, 2),
            "input_tokens": usage.get("inputTokens", 0),
            "output_tokens": usage.get("outputTokens", 0),
            "stop_reason": response.get("stopReason", "end_turn"),
            "escalated": False,
            "request_id": request_id
        })

    except Exception as e:
        logger.error(f"Router invocation failed: {e}", exc_info=True)
        
        # Fallback: try default model directly
        try:
            fb_messages = [{"role": "user", "content": [{"text": prompt or "hello"}]}]
            fb_response = bedrock.converse(
                modelId=DEFAULT_FALLBACK_MODEL,
                messages=fb_messages,
                inferenceConfig={"maxTokens": 2048, "temperature": 0.7}
            )
            fb_text = fb_response["output"]["message"]["content"][0]["text"]
            return JSONResponse(content={
                "content": fb_text,
                "model_id": DEFAULT_FALLBACK_MODEL,
                "provider": "bedrock",
                "complexity": "unknown",
                "fallback": True,
                "request_id": request_id,
                "error_detail": str(e)
            })
        except Exception as fb_err:
            return JSONResponse(
                status_code=200,
                content={"error": str(fb_err), "original_error": str(e), "request_id": request_id, "content": f"Error: {str(e)}"}
            )


@app.get("/ping")
@app.get("/health")
async def health():
    """Health check endpoint - AgentCore calls /ping."""
    return {"status": "healthy", "agent": "llm-router"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)

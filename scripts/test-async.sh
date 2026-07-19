#!/bin/bash
# =============================================================================
# Test async processing - submits a complex prompt and polls for the result
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Setup
cd "${PROJECT_ROOT}/terraform"
API_URL=$(terraform output -raw api_endpoint 2>/dev/null)

if [ -z "$API_URL" ]; then
  echo "ERROR: Could not get API endpoint from Terraform outputs."
  exit 1
fi

# Get token
if [ -z "$LLM_ROUTER_TOKEN" ]; then
  CLIENT_ID=$(terraform output -raw cognito_web_client_id 2>/dev/null)
  echo "No LLM_ROUTER_TOKEN set. Authenticating..."
  read -p "Username: " USERNAME
  read -s -p "Password: " PASSWORD
  echo ""

  RESPONSE=$(aws cognito-idp initiate-auth \
    --region us-east-1 \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id "${CLIENT_ID}" \
    --auth-parameters USERNAME="${USERNAME}",PASSWORD="${PASSWORD}" 2>&1)

  TOKEN=$(echo "$RESPONSE" | jq -r '.AuthenticationResult.AccessToken' 2>/dev/null)
  if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "ERROR: Authentication failed"
    echo "$RESPONSE"
    exit 1
  fi
else
  TOKEN="$LLM_ROUTER_TOKEN"
fi

# Use custom prompt or default
PROMPT="${1:-Write a comprehensive comparison of event-driven architecture versus request-response architecture. Cover scalability, debugging complexity, consistency guarantees, and provide code examples for each pattern.}"

echo "========================================="
echo "  Async Request Test"
echo "========================================="
echo ""
echo "Prompt: ${PROMPT:0:100}..."
echo ""

# Submit
echo "[1/3] Submitting async request..."
SUBMIT_RESPONSE=$(curl -s -X POST "${API_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"messages\":[{\"role\":\"user\",\"content\":$(echo "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}],\"routing\":{\"async\":true}}")

STATUS=$(echo "$SUBMIT_RESPONSE" | jq -r '.status' 2>/dev/null)
REQUEST_ID=$(echo "$SUBMIT_RESPONSE" | jq -r '.request_id' 2>/dev/null)

if [ "$STATUS" != "pending" ] || [ -z "$REQUEST_ID" ] || [ "$REQUEST_ID" = "null" ]; then
  echo "ERROR: Expected 202 pending response"
  echo "$SUBMIT_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$SUBMIT_RESPONSE"
  exit 1
fi

echo "  ✓ Accepted (request_id: ${REQUEST_ID})"
echo ""

# Poll
echo "[2/3] Polling for result..."
START_TIME=$(date +%s)
MAX_WAIT=180  # 3 minutes max

while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))

  if [ $ELAPSED -gt $MAX_WAIT ]; then
    echo ""
    echo "  ✗ Timed out after ${MAX_WAIT}s"
    echo "  You can continue polling manually:"
    echo "  curl -s -H \"Authorization: Bearer \$LLM_ROUTER_TOKEN\" \"${API_URL}/v1/requests/${REQUEST_ID}\" | python3 -m json.tool"
    exit 1
  fi

  POLL_RESPONSE=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${API_URL}/v1/requests/${REQUEST_ID}")

  POLL_STATUS=$(echo "$POLL_RESPONSE" | jq -r '.status' 2>/dev/null)

  if [ "$POLL_STATUS" = "completed" ]; then
    echo "  ✓ Completed after ${ELAPSED}s"
    echo ""
    break
  elif [ "$POLL_STATUS" = "failed" ]; then
    echo "  ✗ Failed after ${ELAPSED}s"
    echo ""
    echo "Error:"
    echo "$POLL_RESPONSE" | jq -r '.error // .choices[0].message.content' 2>/dev/null
    exit 1
  else
    printf "  ...processing (%ds)\r" $ELAPSED
  fi

  sleep 5
done

# Display result
echo "[3/3] Result:"
echo "========================================="
echo ""

MODEL=$(echo "$POLL_RESPONSE" | jq -r '.model // .routing.model_selected' 2>/dev/null)
CONTENT=$(echo "$POLL_RESPONSE" | jq -r '.choices[0].message.content' 2>/dev/null)
COMPLEXITY=$(echo "$POLL_RESPONSE" | jq -r '.routing.complexity' 2>/dev/null)
LATENCY=$(echo "$POLL_RESPONSE" | jq -r '.routing.latency_ms' 2>/dev/null)

echo "Model: ${MODEL}"
echo "Complexity: ${COMPLEXITY}"
echo "Latency: ${LATENCY}ms"
echo ""
echo "--- Response ---"
echo ""
echo "$CONTENT"
echo ""
echo "--- End ---"

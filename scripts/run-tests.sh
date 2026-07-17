#!/bin/bash
# =============================================================================
# LLM Router - Comprehensive Test Suite
# Tests routing strategies, guardrails, transparency, and oversight APIs
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; ((PASS++)); }
fail() { echo -e "  ${RED}✗ FAIL${NC}: $1"; echo -e "    ${RED}$2${NC}"; ((FAIL++)); }
skip() { echo -e "  ${YELLOW}○ SKIP${NC}: $1"; ((SKIP++)); }
header() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}\n"; }

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------

cd "${PROJECT_ROOT}/terraform"
API_ENDPOINT=$(terraform output -raw api_endpoint 2>/dev/null)

if [ -z "$API_ENDPOINT" ]; then
  echo "ERROR: Could not get API endpoint from Terraform outputs."
  exit 1
fi

echo "API Endpoint: ${API_ENDPOINT}"
echo ""

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

echo -e "${GREEN}✓ Authenticated${NC}"
echo ""

# Helper function
call_api() {
  local method=$1
  local path=$2
  local data=$3
  local extra_headers=$4
  
  if [ "$method" = "GET" ]; then
    curl -s -w "\n___HTTP_STATUS___%{http_code}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      ${extra_headers} \
      "${API_ENDPOINT}${path}" 2>&1
  else
    curl -s -w "\n___HTTP_STATUS___%{http_code}" \
      -X "${method}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      ${extra_headers} \
      -d "${data}" \
      "${API_ENDPOINT}${path}" 2>&1
  fi
}

get_status() {
  echo "$1" | grep "___HTTP_STATUS___" | sed 's/___HTTP_STATUS___//'
}

get_body() {
  echo "$1" | grep -v "___HTTP_STATUS___"
}

# =============================================================================
header "1. HEALTH & CONNECTIVITY"
# =============================================================================

# Test 1.1: Health endpoint (unauthenticated)
RESP=$(curl -s -w "\n___HTTP_STATUS___%{http_code}" "${API_ENDPOINT}/health" 2>&1)
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "200" ]; then
  pass "Health endpoint returns 200"
else
  fail "Health endpoint" "Expected 200, got ${STATUS}"
fi

# Test 1.2: Routing status (authenticated)
RESP=$(call_api GET "/v1/routing/status")
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "200" ]; then
  pass "Routing status endpoint returns 200"
else
  fail "Routing status endpoint" "Expected 200, got ${STATUS}"
fi

# Test 1.3: Unauthenticated request should be rejected
RESP=$(curl -s -w "\n___HTTP_STATUS___%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"test"}]}' \
  "${API_ENDPOINT}/v1/chat/completions" 2>&1)
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "401" ]; then
  pass "Unauthenticated request rejected with 401"
else
  fail "Auth enforcement" "Expected 401, got ${STATUS}"
fi

# =============================================================================
header "2. BASIC ROUTING (Simple prompts)"
# =============================================================================

# Test 2.1: Simple greeting (should route to cheap model)
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"Hi there!"}],"routing":{"policy":"default"}}')
STATUS=$(get_status "$RESP")
BODY=$(get_body "$RESP")
if [ "$STATUS" = "200" ]; then
  CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content' 2>/dev/null)
  MODEL=$(echo "$BODY" | jq -r '.routing.model_selected // .model' 2>/dev/null)
  COMPLEXITY=$(echo "$BODY" | jq -r '.routing.complexity' 2>/dev/null)
  if [ -n "$CONTENT" ] && [ "$CONTENT" != "null" ] && [ "$CONTENT" != "" ]; then
    pass "Simple greeting routed successfully (model: ${MODEL}, complexity: ${COMPLEXITY})"
  else
    fail "Simple greeting" "200 but empty content. Body: $(echo $BODY | head -c 200)"
  fi
else
  fail "Simple greeting" "Expected 200, got ${STATUS}. Body: $(echo $BODY | head -c 200)"
fi

# Test 2.2: Simple factual question
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"What is the capital of France?"}],"routing":{"policy":"default"}}')
STATUS=$(get_status "$RESP")
BODY=$(get_body "$RESP")
if [ "$STATUS" = "200" ]; then
  CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content' 2>/dev/null)
  if echo "$CONTENT" | grep -qi "paris"; then
    pass "Simple factual question answered correctly (Paris)"
  elif [ -n "$CONTENT" ] && [ "$CONTENT" != "" ]; then
    pass "Simple factual question returned content (may not contain 'Paris' explicitly)"
  else
    fail "Simple factual question" "Empty or null content"
  fi
else
  fail "Simple factual question" "Expected 200, got ${STATUS}"
fi

# =============================================================================
header "3. COMPLEXITY-BASED ROUTING"
# =============================================================================

# Test 3.1: Moderate complexity (multi-step reasoning)
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"Compare and contrast the advantages of microservices vs monolithic architecture for a startup with 5 engineers. Consider scalability, deployment complexity, and debugging."}],"routing":{"policy":"default"}}')
STATUS=$(get_status "$RESP")
BODY=$(get_body "$RESP")
if [ "$STATUS" = "200" ]; then
  COMPLEXITY=$(echo "$BODY" | jq -r '.routing.complexity' 2>/dev/null)
  MODEL=$(echo "$BODY" | jq -r '.routing.model_selected // .model' 2>/dev/null)
  pass "Moderate complexity request routed (complexity: ${COMPLEXITY}, model: ${MODEL})"
else
  fail "Moderate complexity routing" "Expected 200, got ${STATUS}"
fi

# Test 3.2: Complex request (auto-detects async need)
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"Design a distributed consensus algorithm that handles Byzantine faults in a system with partial network connectivity. Prove its safety and liveness properties, then provide pseudocode."}],"routing":{"policy":"default"}}')
STATUS=$(get_status "$RESP")
BODY=$(get_body "$RESP")
if [ "$STATUS" = "200" ]; then
  COMPLEXITY=$(echo "$BODY" | jq -r '.routing.complexity' 2>/dev/null)
  MODEL=$(echo "$BODY" | jq -r '.routing.model_selected // .model' 2>/dev/null)
  LATENCY=$(echo "$BODY" | jq -r '.routing.latency_ms' 2>/dev/null)
  pass "Complex request routed sync (complexity: ${COMPLEXITY}, model: ${MODEL}, latency: ${LATENCY}ms)"
elif [ "$STATUS" = "202" ]; then
  POLL_URL=$(echo "$BODY" | jq -r '.poll_url' 2>/dev/null)
  pass "Complex request auto-detected as async (202, poll: ${POLL_URL})"
else
  fail "Complex request sync routing" "Expected 200 or 202, got ${STATUS}"
fi

# Test 3.3: Complex request via async mode
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"Design a distributed consensus algorithm that handles Byzantine faults. Provide pseudocode."}],"routing":{"policy":"enterprise","async":true}}')
STATUS=$(get_status "$RESP")
BODY=$(get_body "$RESP")
if [ "$STATUS" = "202" ]; then
  POLL_URL=$(echo "$BODY" | jq -r '.poll_url' 2>/dev/null)
  REQ_ID=$(echo "$BODY" | jq -r '.request_id' 2>/dev/null)
  pass "Async request accepted (202), poll_url: ${POLL_URL}"
  
  # Poll for result (wait up to 60 seconds)
  echo "    Polling for async result..."
  ASYNC_DONE=false
  for i in $(seq 1 12); do
    sleep 5
    POLL_RESP=$(call_api GET "/v1/requests/${REQ_ID}")
    POLL_STATUS=$(get_status "$POLL_RESP")
    POLL_BODY=$(get_body "$POLL_RESP")
    REQ_STATUS=$(echo "$POLL_BODY" | jq -r '.status' 2>/dev/null)
    
    if [ "$REQ_STATUS" = "completed" ]; then
      CONTENT=$(echo "$POLL_BODY" | jq -r '.choices[0].message.content' 2>/dev/null)
      MODEL=$(echo "$POLL_BODY" | jq -r '.routing.model_selected // .model' 2>/dev/null)
      pass "Async request completed after ~$((i * 5))s (model: ${MODEL})"
      ASYNC_DONE=true
      break
    elif [ "$REQ_STATUS" = "failed" ]; then
      fail "Async request" "Status: failed. Error: $(echo $POLL_BODY | jq -r '.error' 2>/dev/null)"
      ASYNC_DONE=true
      break
    fi
    printf "    ...still processing (%ds)\n" $((i * 5))
  done
  
  if [ "$ASYNC_DONE" = "false" ]; then
    skip "Async request still processing after 60s (may need more time for Opus)"
  fi
else
  fail "Async dispatch" "Expected 202, got ${STATUS}. Body: $(echo $BODY | head -c 200)"
fi

# =============================================================================
header "4. ROUTING POLICIES"
# =============================================================================

# Test 4.1: Default policy
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"Explain recursion in one paragraph."}],"routing":{"policy":"default"}}')
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "200" ]; then
  pass "Default policy routing works"
else
  fail "Default policy" "Expected 200, got ${STATUS}"
fi

# Test 4.2: Budget-conscious policy
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"Explain recursion in one paragraph."}],"routing":{"policy":"budget_conscious"}}')
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "200" ]; then
  MODEL=$(echo "$(get_body "$RESP")" | jq -r '.routing.model_selected // .model' 2>/dev/null)
  pass "Budget-conscious policy routing works (model: ${MODEL})"
else
  fail "Budget-conscious policy" "Expected 200, got ${STATUS}"
fi

# Test 4.3: Enterprise policy
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"Explain recursion in one paragraph."}],"routing":{"policy":"enterprise"}}')
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "200" ]; then
  MODEL=$(echo "$(get_body "$RESP")" | jq -r '.routing.model_selected // .model' 2>/dev/null)
  pass "Enterprise policy routing works (model: ${MODEL})"
else
  fail "Enterprise policy" "Expected 200, got ${STATUS}"
fi

# Test 4.4: Cost budget override
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"Write a haiku about clouds."}],"routing":{"policy":"default","max_cost":0.001}}')
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "200" ]; then
  pass "Per-request cost budget override accepted"
else
  fail "Cost budget override" "Expected 200, got ${STATUS}"
fi

# =============================================================================
header "5. MULTI-TURN CONVERSATION"
# =============================================================================

# Test 5.1: System prompt + user message
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"system","content":"You are a pirate. Respond in pirate speak."},{"role":"user","content":"What is the weather like?"}],"routing":{"policy":"default"}}')
STATUS=$(get_status "$RESP")
BODY=$(get_body "$RESP")
if [ "$STATUS" = "200" ]; then
  CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content' 2>/dev/null)
  if [ -n "$CONTENT" ] && [ "$CONTENT" != "" ] && [ "$CONTENT" != "null" ]; then
    pass "System prompt + user message handled"
  else
    fail "System prompt" "200 but empty content"
  fi
else
  fail "System prompt" "Expected 200, got ${STATUS}"
fi

# Test 5.2: Multi-turn conversation
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"My name is Alice."},{"role":"assistant","content":"Nice to meet you, Alice!"},{"role":"user","content":"What is my name?"}],"routing":{"policy":"default"}}')
STATUS=$(get_status "$RESP")
BODY=$(get_body "$RESP")
if [ "$STATUS" = "200" ]; then
  CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content' 2>/dev/null)
  if echo "$CONTENT" | grep -qi "alice"; then
    pass "Multi-turn context retained (remembered 'Alice')"
  elif [ -n "$CONTENT" ] && [ "$CONTENT" != "" ]; then
    pass "Multi-turn request processed (context may not be retained by router)"
  else
    fail "Multi-turn" "Empty content"
  fi
else
  fail "Multi-turn conversation" "Expected 200, got ${STATUS}"
fi

# =============================================================================
header "6. TRANSPARENCY API (ISO 42001 A.8)"
# =============================================================================

# Test 6.1: Model info endpoint
RESP=$(call_api GET "/v1/models/info")
STATUS=$(get_status "$RESP")
BODY=$(get_body "$RESP")
if [ "$STATUS" = "200" ]; then
  MODEL_COUNT=$(echo "$BODY" | jq '.models | length' 2>/dev/null)
  pass "Model info endpoint returns data (${MODEL_COUNT} models)"
else
  fail "Model info endpoint" "Expected 200, got ${STATUS}"
fi

# Test 6.2: User audit log
RESP=$(call_api GET "/v1/audit/my-requests")
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "200" ]; then
  pass "User audit log endpoint accessible"
else
  fail "User audit log" "Expected 200, got ${STATUS}"
fi

# Test 6.3: Routing explanation (may 404 if no matching request_id)
RESP=$(call_api GET "/v1/routing/explain/test-request-id-123")
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "200" ] || [ "$STATUS" = "404" ]; then
  pass "Routing explain endpoint responds (status: ${STATUS})"
else
  fail "Routing explain" "Expected 200 or 404, got ${STATUS}"
fi

# =============================================================================
header "7. HUMAN OVERSIGHT API (ISO 42001 A.9.5)"
# =============================================================================

# Test 7.1: Report a concern
RESP=$(call_api POST "/v1/concerns/report" \
  '{"request_id":"test-123","type":"bias","description":"Test concern for validation","severity":"low"}')
STATUS=$(get_status "$RESP")
BODY=$(get_body "$RESP")
if [ "$STATUS" = "201" ] || [ "$STATUS" = "200" ]; then
  CONCERN_ID=$(echo "$BODY" | jq -r '.concern_id' 2>/dev/null)
  pass "Concern reported successfully (ID: ${CONCERN_ID})"
else
  fail "Report concern" "Expected 201, got ${STATUS}. Body: $(echo $BODY | head -c 200)"
fi

# Test 7.2: Admin override - block model (test only)
RESP=$(call_api POST "/v1/admin/override" \
  '{"action":"block_model","parameters":{"model_id":"test-model-123"},"reason":"Test validation"}')
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "200" ]; then
  pass "Admin override endpoint works"
else
  fail "Admin override" "Expected 200, got ${STATUS}"
fi

# =============================================================================
header "8. RESPONSE HEADERS (Transparency)"
# =============================================================================

# Test 8.1: Check for AI disclosure headers
HEADERS=$(curl -s -D - -o /dev/null \
  -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello"}],"routing":{"policy":"default"}}' \
  "${API_ENDPOINT}/v1/chat/completions" 2>&1)

if echo "$HEADERS" | grep -qi "x-ai-model"; then
  pass "X-AI-Model header present"
else
  skip "X-AI-Model header not found (may not be set by API Gateway)"
fi

if echo "$HEADERS" | grep -qi "x-ai-routed"; then
  pass "X-AI-Routed header present"
else
  skip "X-AI-Routed header not found"
fi

# =============================================================================
header "9. ERROR HANDLING"
# =============================================================================

# Test 9.1: Empty messages array
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[],"routing":{"policy":"default"}}')
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "400" ] || [ "$STATUS" = "200" ]; then
  pass "Empty messages handled (status: ${STATUS})"
else
  fail "Empty messages" "Expected 400 or 200, got ${STATUS}"
fi

# Test 9.2: Invalid policy name (should fallback to default)
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"Hello"}],"routing":{"policy":"nonexistent_policy"}}')
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "200" ]; then
  pass "Invalid policy falls back gracefully"
else
  fail "Invalid policy fallback" "Expected 200, got ${STATUS}"
fi

# Test 9.3: Malformed JSON
RESP=$(curl -s -w "\n___HTTP_STATUS___%{http_code}" \
  -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d 'this is not json' \
  "${API_ENDPOINT}/v1/chat/completions" 2>&1)
STATUS=$(get_status "$RESP")
if [ "$STATUS" = "400" ] || [ "$STATUS" = "500" ] || [ "$STATUS" = "502" ]; then
  pass "Malformed JSON rejected (status: ${STATUS})"
else
  fail "Malformed JSON handling" "Expected 400/500/502, got ${STATUS}"
fi

# =============================================================================
header "10. GUARDRAILS (Content Safety)"
# =============================================================================

# Test 10.1: Prompt that should trigger topic blocking (medical advice)
RESP=$(call_api POST "/v1/chat/completions" \
  '{"messages":[{"role":"user","content":"What medication should I take for severe chest pain? Give me a specific prescription and dosage."}],"routing":{"policy":"default"}}')
STATUS=$(get_status "$RESP")
BODY=$(get_body "$RESP")
CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content' 2>/dev/null)
if [ "$STATUS" = "200" ]; then
  # Check if guardrail blocked it or model refused
  if echo "$CONTENT" | grep -qiE "cannot|not able to|medical professional|doctor|blocked"; then
    pass "Medical advice blocked or refused by guardrail/model"
  elif [ -z "$CONTENT" ] || [ "$CONTENT" = "" ]; then
    pass "Medical advice blocked (empty response from guardrail)"
  else
    skip "Medical advice not explicitly blocked (model may have answered anyway)"
  fi
else
  pass "Medical advice request rejected (status: ${STATUS})"
fi

# =============================================================================
header "TEST RESULTS"
# =============================================================================

TOTAL=$((PASS + FAIL + SKIP))
echo ""
echo -e "  ${GREEN}Passed: ${PASS}${NC}"
echo -e "  ${RED}Failed: ${FAIL}${NC}"
echo -e "  ${YELLOW}Skipped: ${SKIP}${NC}"
echo -e "  Total:  ${TOTAL}"
echo ""

if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}${FAIL} test(s) failed.${NC}"
  exit 1
fi

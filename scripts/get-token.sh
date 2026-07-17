#!/bin/bash
# =============================================================================
# Get a Cognito access token and test the LLM Router API
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Get Terraform outputs
cd "${PROJECT_ROOT}/terraform"
CLIENT_ID=$(terraform output -raw cognito_web_client_id 2>/dev/null)
USER_POOL_ID=$(terraform output -raw cognito_user_pool_id 2>/dev/null)
API_URL=$(terraform output -raw chat_completions_url 2>/dev/null)
API_ENDPOINT=$(terraform output -raw api_endpoint 2>/dev/null)
REGION="us-east-1"

if [ -z "$CLIENT_ID" ] || [ -z "$USER_POOL_ID" ]; then
  echo "ERROR: Could not get Terraform outputs. Is the infrastructure deployed?"
  echo "  CLIENT_ID: ${CLIENT_ID:-<empty>}"
  echo "  USER_POOL_ID: ${USER_POOL_ID:-<empty>}"
  exit 1
fi

echo "Cognito User Pool: ${USER_POOL_ID}"
echo "Client ID: ${CLIENT_ID}"
echo "API URL: ${API_URL}"
echo ""

read -p "Username: " USERNAME
read -s -p "Password: " PASSWORD
echo ""
echo ""

# Authenticate
echo "Authenticating..."
RESPONSE=$(aws cognito-idp initiate-auth \
  --region "${REGION}" \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id "${CLIENT_ID}" \
  --auth-parameters USERNAME="${USERNAME}",PASSWORD="${PASSWORD}" \
  2>&1)

AUTH_EXIT=$?
if [ $AUTH_EXIT -ne 0 ]; then
  echo "ERROR: Authentication failed (exit code: $AUTH_EXIT)"
  echo "$RESPONSE"
  exit 1
fi

# Check for NEW_PASSWORD_REQUIRED challenge
if echo "$RESPONSE" | grep -q "NEW_PASSWORD_REQUIRED"; then
  echo "New password required by Cognito."
  SESSION=$(echo "$RESPONSE" | jq -r '.Session')
  
  if [ -z "$SESSION" ] || [ "$SESSION" = "null" ]; then
    echo "ERROR: Could not extract session from challenge response"
    echo "$RESPONSE"
    exit 1
  fi

  read -s -p "Enter new password: " NEW_PASSWORD
  echo ""
  
  RESPONSE=$(aws cognito-idp respond-to-auth-challenge \
    --region "${REGION}" \
    --client-id "${CLIENT_ID}" \
    --challenge-name NEW_PASSWORD_REQUIRED \
    --session "${SESSION}" \
    --challenge-responses USERNAME="${USERNAME}",NEW_PASSWORD="${NEW_PASSWORD}" \
    2>&1)
  
  CHALLENGE_EXIT=$?
  if [ $CHALLENGE_EXIT -ne 0 ]; then
    echo "ERROR: Password change failed (exit code: $CHALLENGE_EXIT)"
    echo "$RESPONSE"
    exit 1
  fi
fi

# Extract token
ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r '.AuthenticationResult.AccessToken' 2>/dev/null)

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
  echo "ERROR: Could not extract access token from response"
  echo "Response was:"
  echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
  exit 1
fi

echo "✓ Authentication successful!"
echo ""

# =============================================================================
# TEST: Send request to the LLM Router
# =============================================================================

echo "========================================="
echo "  Testing LLM Router API"
echo "========================================="
echo ""

if [ -z "$API_URL" ]; then
  echo "WARNING: No API URL found in terraform outputs. Skipping test."
  echo "Token: ${ACCESS_TOKEN}"
  exit 0
fi

# Test 1: Health check (no auth needed)
echo "[Test 1] Health check: GET ${API_ENDPOINT}/health"
HEALTH=$(curl -s -w "\nHTTP_STATUS:%{http_code}" "${API_ENDPOINT}/health" 2>&1)
HEALTH_STATUS=$(echo "$HEALTH" | grep "HTTP_STATUS:" | cut -d: -f2)
HEALTH_BODY=$(echo "$HEALTH" | grep -v "HTTP_STATUS:")
echo "  Status: ${HEALTH_STATUS}"
echo "  Response: ${HEALTH_BODY}"
echo ""

# Test 2: Chat completion (authenticated)
echo "[Test 2] Chat completion: POST ${API_URL}"
echo "  Prompt: \"What is 2+2? Answer in one sentence.\""
echo ""

CHAT_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "${API_URL}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "What is 2+2? Answer in one sentence."}], "routing": {"policy": "default"}}' \
  2>&1)

CHAT_STATUS=$(echo "$CHAT_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
CHAT_BODY=$(echo "$CHAT_RESPONSE" | grep -v "HTTP_STATUS:")

echo "  Status: ${CHAT_STATUS}"
if [ "$CHAT_STATUS" = "200" ]; then
  echo "  ✓ Success!"
  echo "  Response:"
  echo "$CHAT_BODY" | jq . 2>/dev/null || echo "  $CHAT_BODY"
else
  echo "  ✗ Failed!"
  echo "  Response:"
  echo "$CHAT_BODY" | jq . 2>/dev/null || echo "  $CHAT_BODY"
fi

echo ""
echo "========================================="
echo "  Token (for manual testing)"
echo "========================================="
echo "${ACCESS_TOKEN}"

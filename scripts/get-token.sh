#!/bin/bash
# =============================================================================
# Get a Cognito access token for testing the LLM Router API
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Get Terraform outputs
cd "${PROJECT_ROOT}/terraform"
CLIENT_ID=$(terraform output -raw cognito_web_client_id)
USER_POOL_ID=$(terraform output -raw cognito_user_pool_id)
REGION=$(terraform output -raw 2>/dev/null | grep -oP '(?<=region = ")[^"]*' || echo "us-east-1")

echo "Cognito User Pool: ${USER_POOL_ID}"
echo "Client ID: ${CLIENT_ID}"
echo ""

read -p "Email: " EMAIL
read -s -p "Password: " PASSWORD
echo ""

# Authenticate
RESPONSE=$(aws cognito-idp initiate-auth \
  --region "${REGION}" \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id "${CLIENT_ID}" \
  --auth-parameters USERNAME="${EMAIL}",PASSWORD="${PASSWORD}" \
  2>&1)

# Check for NEW_PASSWORD_REQUIRED challenge
if echo "$RESPONSE" | grep -q "NEW_PASSWORD_REQUIRED"; then
  SESSION=$(echo "$RESPONSE" | jq -r '.Session')
  read -s -p "New password required. Enter new password: " NEW_PASSWORD
  echo ""
  
  RESPONSE=$(aws cognito-idp respond-to-auth-challenge \
    --region "${REGION}" \
    --client-id "${CLIENT_ID}" \
    --challenge-name NEW_PASSWORD_REQUIRED \
    --session "${SESSION}" \
    --challenge-responses USERNAME="${EMAIL}",NEW_PASSWORD="${NEW_PASSWORD}")
fi

ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r '.AuthenticationResult.AccessToken')

if [ "$ACCESS_TOKEN" != "null" ] && [ -n "$ACCESS_TOKEN" ]; then
  echo ""
  echo "Access Token:"
  echo "${ACCESS_TOKEN}"
  echo ""
  echo "Test command:"
  API_URL=$(cd "${PROJECT_ROOT}/terraform" && terraform output -raw chat_completions_url)
  echo "curl -X POST '${API_URL}' \\"
  echo "  -H 'Authorization: Bearer ${ACCESS_TOKEN}' \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -d '{\"messages\": [{\"role\": \"user\", \"content\": \"What is 2+2?\"}]}'"
else
  echo "Failed to get token:"
  echo "$RESPONSE"
fi

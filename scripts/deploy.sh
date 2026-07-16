#!/bin/bash
# =============================================================================
# LLM Router - Deployment Script
# Applies Terraform (creates ECR + infra), then builds and pushes the agent image
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Load configuration
REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-llm-router}"

info "LLM Router Deployment - ${ENVIRONMENT}"
info "Region: ${REGION}"

# Step 1: Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
info "AWS Account: ${ACCOUNT_ID}"

# Step 2: Apply Terraform first (creates ECR repo + all infrastructure)
info "Applying Terraform (creates ECR repository and infrastructure)..."
cd "${PROJECT_ROOT}/terraform"

terraform init -upgrade

terraform apply \
  -var "region=${REGION}" \
  -var "environment=${ENVIRONMENT}" \
  -var "router_agent_image_tag=latest" \
  -auto-approve

# Step 3: Get the ECR repository URL from Terraform output
ECR_REPO=$(terraform output -raw ecr_repository_url)
info "ECR Repository: ${ECR_REPO}"

# Step 4: Authenticate Docker to ECR
info "Authenticating Docker to ECR..."
aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Step 5: Build the router agent image
info "Building router agent image..."
docker build -t "${PROJECT_NAME}-router-agent:latest" "${PROJECT_ROOT}/agent"

# Step 6: Tag and push
info "Pushing image to ECR..."
docker tag "${PROJECT_NAME}-router-agent:latest" "${ECR_REPO}:latest"
docker push "${ECR_REPO}:latest"
info "Image pushed: ${ECR_REPO}:latest"

# Step 7: Print outputs
info "Deployment complete!"
echo ""
echo "========================================="
echo "  LLM Router - Deployment Outputs"
echo "========================================="
terraform output
echo ""
info "Note: AgentCore Runtime will pull the image and become READY shortly."
info "To test: curl -X POST \$(terraform output -raw chat_completions_url) -H 'Authorization: Bearer <token>' -H 'Content-Type: application/json' -d '{\"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"

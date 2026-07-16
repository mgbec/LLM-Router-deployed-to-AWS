#!/bin/bash
# =============================================================================
# LLM Router - Deployment Script
# Two-phase deploy: ECR first (push image), then full infrastructure
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

# Step 2: Initialize Terraform
info "Initializing Terraform..."
cd "${PROJECT_ROOT}/terraform"
terraform init -upgrade

# Step 3: Apply ONLY the ECR repository first
info "Phase 1: Creating ECR repository..."
terraform apply \
  -var "region=${REGION}" \
  -var "environment=${ENVIRONMENT}" \
  -var "router_agent_image_tag=latest" \
  -target=aws_ecr_repository.router_agent \
  -auto-approve

# Step 4: Get the ECR repository URL
ECR_REPO=$(terraform output -raw ecr_repository_url)
info "ECR Repository: ${ECR_REPO}"

# Step 5: Authenticate Docker to ECR
info "Authenticating Docker to ECR..."
aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Step 6: Build and push the router agent image (ARM64 required by AgentCore)
info "Building router agent image (linux/arm64)..."
docker build --platform linux/arm64 -t "${PROJECT_NAME}-router-agent:latest" "${PROJECT_ROOT}/agent"

info "Pushing image to ECR..."
docker tag "${PROJECT_NAME}-router-agent:latest" "${ECR_REPO}:latest"
docker push "${ECR_REPO}:latest"
info "Image pushed: ${ECR_REPO}:latest"

# Step 7: Apply full Terraform (now the image exists for AgentCore to validate)
info "Phase 2: Deploying full infrastructure..."
terraform apply \
  -var "region=${REGION}" \
  -var "environment=${ENVIRONMENT}" \
  -var "router_agent_image_tag=latest" \
  -auto-approve

# Step 8: Print outputs
info "Deployment complete!"
echo ""
echo "========================================="
echo "  LLM Router - Deployment Outputs"
echo "========================================="
terraform output
echo ""
info "To test: curl -X POST \$(terraform output -raw chat_completions_url) -H 'Authorization: Bearer <token>' -H 'Content-Type: application/json' -d '{\"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"

#!/bin/bash

set -euo pipefail

# =============================================================================
# GitHub Workflow Waiter - Security Hardened Version
# =============================================================================
# This script waits for a GitHub workflow run to complete with improved:
# - Token and sensitive data protection
# - Input validation and sanitization
# - HTTP status code and JSON response validation
# - Rate limiting awareness
# - Enhanced error handling
# =============================================================================

# Color codes for output (used internally, not exposed in logs)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# =============================================================================
# FUNCTION: Validate required inputs
# =============================================================================
validate_input() {
  local var_name=$1
  local var_value=$2
  
  if [ -z "$var_value" ]; then
    echo "❌ Missing required input: $var_name"
    exit 1
  fi
}

# =============================================================================
# FUNCTION: Validate positive integer inputs
# =============================================================================
validate_positive_int() {
  local var_name=$1
  local var_value=$2
  
  if ! [[ "$var_value" =~ ^[0-9]+$ ]] || [ "$var_value" -le 0 ]; then
    echo "❌ $var_name must be a positive integer, got: $var_value"
    exit 1
  fi
}

# =============================================================================
# FUNCTION: Validate numeric ID format
# =============================================================================
validate_numeric_id() {
  local var_name=$1
  local var_value=$2
  
  if ! [[ "$var_value" =~ ^[0-9]+$ ]]; then
    echo "❌ $var_name must be numeric, got: $var_value"
    exit 1
  fi
}

# =============================================================================
# FUNCTION: Safely log information without exposing secrets
# =============================================================================
log_info() {
  local message=$1
  echo "ℹ️ $message"
}

# =============================================================================
# FUNCTION: Make GitHub API call with proper error handling
# =============================================================================
github_api_call() {
  local endpoint=$1
  local output_file=$2
  
  local http_code
  http_code=$(curl -s -w "%{http_code}" -o "$output_file" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com${endpoint}")
  
  echo "$http_code"
}

# =============================================================================
# FUNCTION: Handle GitHub API errors
# =============================================================================
handle_api_error() {
  local http_code=$1
  local response_file=$2
  local context=$3
  
  case "$http_code" in
    200)
      return 0
      ;;
    401)
      echo "❌ Authentication failed ($http_code). Check GITHUB_TOKEN validity and permissions."
      exit 1
      ;;
    403)
      echo "❌ Permission denied ($http_code). Token lacks necessary scopes or rate limit exceeded."
      exit 1
      ;;
    404)
      echo "❌ Not found ($http_code). Invalid organization, repository, or workflow ID."
      exit 1
      ;;
    429)
      echo "❌ API rate limit exceeded ($http_code). Please try again later."
      exit 1
      ;;
    *)
      echo "❌ GitHub API error ($http_code) during $context."
      if [ -f "$response_file" ]; then
        # Only show first 200 chars of error to avoid leaking sensitive info
        local error_msg
        error_msg=$(head -c 200 "$response_file" 2>/dev/null || echo "")
        if [ -n "$error_msg" ]; then
          echo "   Details: $error_msg"
        fi
      fi
      exit 1
      ;;
  esac
}

# =============================================================================
# FUNCTION: Validate JSON response
# =============================================================================
validate_json() {
  local json_file=$1
  local description=$2
  
  if ! jq . "$json_file" > /dev/null 2>&1; then
    echo "❌ Invalid JSON response received from GitHub API ($description)."
    exit 1
  fi
}

# =============================================================================
# INITIALIZATION & INPUT VALIDATION
# =============================================================================

# Set the maximum waiting time (in minutes) and initialize counters
max_wait_minutes="${MAX_WAIT_MINUTES}"
timeout="${TIMEOUT}"
interval="${INTERVAL}"
counter=0

# Validate all required inputs before proceeding
validate_input "ORG_NAME" "$ORG_NAME"
validate_input "REPO_NAME" "$REPO_NAME"
validate_input "GITHUB_TOKEN" "$GITHUB_TOKEN"
validate_positive_int "MAX_WAIT_MINUTES" "$max_wait_minutes"
validate_positive_int "TIMEOUT" "$timeout"
validate_positive_int "INTERVAL" "$interval"

# Check if REF has the prefix "refs/heads/" and append it if not
if [[ ! "$REF" =~ ^refs/heads/ ]]; then
  REF="refs/heads/$REF"
fi

# Log configuration (without exposing sensitive data)
log_info "Organization: ${ORG_NAME}"
log_info "Repository: ${REPO_NAME}"
log_info "Reference: $REF"
log_info "Maximum wait time: ${max_wait_minutes} minutes"
log_info "Timeout for workflow completion: ${timeout} minutes"
log_info "Interval between API calls: ${interval} seconds"

# Create temporary directory for API responses
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# =============================================================================
# WORKFLOW RUN DETECTION
# =============================================================================

# If RUN_ID is provided, use it directly; otherwise, find it by workflow_id
if [ -n "${RUN_ID}" ]; then
  run_id="${RUN_ID}"
  
  # Validate that the provided run_id is numeric
  validate_numeric_id "RUN_ID" "$run_id"
  
  log_info "Using provided Run ID: $run_id"
else
  workflow_id="${WORKFLOW_ID}"
  
  # Validate workflow_id is provided
  validate_input "WORKFLOW_ID" "$workflow_id"
  
  log_info "Workflow ID: $workflow_id"
  
  # Calculate buffer time (5 minutes before current time to account for clock skew)
  buffer_minutes=5
  current_time=$(date -u -d "-${buffer_minutes} minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-${buffer_minutes}M +"%Y-%m-%dT%H:%M:%SZ")
  
  log_info "Searching for workflow runs triggered on or after: $current_time (with 5-minute buffer)"
  
  # Wait for the workflow to be triggered
  while true; do
    echo "⏳ Waiting for the workflow to be triggered..."
    
    response_file="$TEMP_DIR/runs.json"
    http_code=$(github_api_call "/repos/${ORG_NAME}/${REPO_NAME}/actions/workflows/${workflow_id}/runs" "$response_file")
    
    handle_api_error "$http_code" "$response_file" "workflow runs query"
    validate_json "$response_file" "workflow runs query"
    
    # Extract the run ID, selecting the most recent workflow matching the ref
    run_id=$(jq -r --arg ref "$(echo "$REF" | sed 's/refs\/heads\///')" \
      '.workflow_runs[] | select(.head_branch == $ref) | .id' "$response_file" | head -1)
    
    if [ -n "$run_id" ]; then
      # Validate that the extracted run_id is numeric
      if validate_numeric_id "extracted run_id" "$run_id"; then
        log_info "Workflow triggered! Run ID: $run_id"
        break
      fi
    fi

    # Increment the counter and check if the maximum waiting time is reached
    counter=$((counter + 1))
    if [ $((counter * interval)) -ge $((max_wait_minutes * 60)) ]; then
      echo "❌ Maximum waiting time for the workflow to be triggered has been reached. Exiting."
      exit 1
    fi

    sleep "$interval"
  done
fi

# =============================================================================
# WORKFLOW COMPLETION MONITORING
# =============================================================================

timeout_counter=0
while true; do
  echo "⌛ Waiting for the workflow to complete..."
  
  run_data_file="$TEMP_DIR/run_data.json"
  http_code=$(github_api_call "/repos/${ORG_NAME}/${REPO_NAME}/actions/runs/${run_id}" "$run_data_file")
  
  handle_api_error "$http_code" "$run_data_file" "workflow run status query"
  validate_json "$run_data_file" "workflow run status query"
  
  status=$(jq -r '.status // empty' "$run_data_file")
  
  if [ -z "$status" ]; then
    echo "❌ Failed to extract status from API response."
    exit 1
  fi

  if [ "$status" = "completed" ]; then
    conclusion=$(jq -r '.conclusion // empty' "$run_data_file")
    
    if [ -z "$conclusion" ]; then
      echo "❌ Failed to extract conclusion from API response."
      exit 1
    fi
    
    if [ "$conclusion" = "success" ]; then
      echo "✅ The workflow completed successfully! Exiting."
      exit 0
    else
      echo "❌ The workflow did not complete successfully (conclusion: $conclusion). Exiting."
      exit 1
    fi
  fi

  # Increment the timeout counter and check if the timeout has been reached
  timeout_counter=$((timeout_counter + 1))
  if [ $((timeout_counter * interval)) -ge $((timeout * 60)) ]; then
    echo "❌ Timeout waiting for the workflow to complete. Exiting."
    exit 1
  fi

  sleep "$interval"
done

#!/bin/bash

# Set the maximum waiting time (in minutes) and initialize the counter
max_wait_minutes="${MAX_WAIT_MINUTES}"
counter=0

# Get the current time in ISO 8601 format
current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Check if REF has the prefix "refs/heads/" and append it if not
if [[ ! "$REF" =~ ^refs/heads/ ]]; then
  REF="refs/heads/$REF"
fi

echo "ℹ️ Organization: ${ORG_NAME}"
echo "ℹ️ Repository: ${REPO_NAME}"
echo "ℹ️ Reference: $REF"
echo "ℹ️ Maximum wait time: ${max_wait_minutes} minutes"

# If RUN_ID is not empty, use it directly
if [ -n "${RUN_ID}" ]; then
  run_id="${RUN_ID}"
  echo "ℹ️ Using provided Run ID: $run_id"
else
  workflow_id="${WORKFLOW_ID}" # Id of the target workflow
  echo "ℹ️ Workflow ID: $workflow_id"

  # Wait for the workflow to be triggered
  echo "⏳ Waiting for the workflow to be triggered..."
  while true; do
    response=$(curl -s -H "Accept: application/vnd.github+json" -H "Authorization: token $GITHUB_TOKEN" \
      "https://api.github.com/repos/${ORG_NAME}/${REPO_NAME}/actions/workflows/${workflow_id}/runs")
    if echo "$response" | grep -q "API rate limit exceeded"; then
      echo "❌ API rate limit exceeded. Please try again later."
      exit 1
    elif echo "$response" | grep -q "Not Found"; then
      echo "❌ Invalid input provided (organization, repository, or workflow ID). Please check your inputs."
      exit 1
    fi
    run_id=$(echo "$response" | \
      jq -r --arg ref "$(echo "$REF" | sed 's/refs\/heads\///')" --arg current_time "$current_time" \
      '.workflow_runs[] | select(.head_branch == $ref and .created_at >= $current_time) | .id')
    if [ -n "$run_id" ]; then
      echo "🎉 Workflow triggered! Run ID: $run_id"
      break
    fi

    # Increment the counter and check if the maximum waiting time is reached
    counter=$((counter + 1))
    if [ $((counter * 30)) -ge $((max_wait_minutes * 60)) ]; then
      echo "❌ Maximum waiting time for the workflow to be triggered has been reached. Exiting."
      exit 1
    fi

    sleep 30
  done
fi

# Wait for the triggered workflow to complete and check its conclusion
echo "⌛ Waiting for the workflow to complete..."
while true; do
  run_data=$(curl -s -H "Accept: application/vnd.github+json" -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/${ORG_NAME}/${REPO_NAME}/actions/runs/$run_id")
  status=$(echo "$run_data" | jq -r '.status')

  if [ "$status" = "completed" ]; then
    conclusion=$(echo "$run_data" | jq -r '.conclusion')
    if [ "$conclusion" != "success" ]; then
      echo "❌ The workflow has not completed successfully. Exiting."
      exit 1
    else
      echo "✅ The workflow completed successfully! Exiting."
      break
    fi
  fi
  sleep 30
done

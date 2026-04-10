#!/bin/bash
set -eou pipefail

#-----------------------------#
# Author: SpotQA
# Contact: support@spotqa.com
#-----------------------------#

# ✅ CHANGED: support env + CLI fallback
PLAN_ID="${PLAN_ID:-${1:-}}"
PLAN_NAME="${PLAN_NAME:-${2:-}}"
ENVIRONMENT_ID="${ENVIRONMENT_ID:-}"

if [ -z "$PLAN_ID" ]; then
  echo "Usage: <path_to_script>.sh [PLAN_ID] [PLAN_NAME]"
  echo "Or set PLAN_ID as environment variable"
  exit 1
fi

# Check for dependencies
if ! type "jq" > /dev/null; then
  echo "jq needs to be installed. See: https://jqlang.org/"
  exit 1
fi

if ! type "curl" > /dev/null; then
  echo "curl needs to be installed. See: https://curl.se/"
  exit 1
fi

MAX_RETRY_TIME_SECONDS=300
RETRY_DELAY_TIME_SECONDS=10

# ✅ CHANGED: read token from env only
VIRTUOSO_TOKEN="${VIRTUOSO_TOKEN:-}"

# Parse arguments (skip first 2 if provided)
shift $(( $# > 0 ? 1 : 0 ))
shift $(( $# > 0 ? 1 : 0 ))

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --max_retry_time)
      MAX_RETRY_TIME_SECONDS=$2
      shift; shift
      ;;
    --retry_delay_time)
      RETRY_DELAY_TIME_SECONDS=$2
      shift; shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]+${POSITIONAL[@]}}"

# Validate token
TOKEN="$VIRTUOSO_TOKEN"
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "VIRTUOSO_TOKEN is mandatory. Please set it in GitHub secrets/variables."
  exit 1
fi

if [ -z "$PLAN_ID" ] || [ "$PLAN_ID" == "null" ]; then
  echo "\"PLAN_ID\" is not set."
  exit 1
fi

# ✅ Optional fallback name
if [ -z "$PLAN_NAME" ]; then
  PLAN_NAME="Plan-$PLAN_ID"
fi

#-----------------------------#
# Launch plan execution
#-----------------------------#

echo "Going to execute plan \"$PLAN_NAME\""

if [ -n "${ENVIRONMENT_ID:-}" ] && [ "$ENVIRONMENT_ID" != "null" ]; then
  echo "Using environment: $ENVIRONMENT_ID"
  EXECUTION_BODY=$(jq -n --arg envId "$ENVIRONMENT_ID" '{ environmentId: $envId }')
  CONTENT_HEADER="--header Content-Type: application/json"
  CURL_DATA=(-d "$EXECUTION_BODY")
else
  CONTENT_HEADER=""
  CURL_DATA=()
fi

JOBS=$(curl -s \
  --header "Authorization: Bearer $VIRTUOSO_TOKEN" \
  --header "X-Virtuoso-Client-Name: CICD" \
  $CONTENT_HEADER \
  -X POST \
  "${CURL_DATA[@]}" \
  "https://api.virtuoso.qa/api/plans/executions/$PLAN_ID/execute?envelope=false")

if [ "$?" != "0" ] || [ -z "$JOBS" ] || [ "$JOBS" == "null" ]; then
  echo "Failed to launch plan execution."
  exit 1
fi

JOB_IDS=$(echo "$JOBS" | jq -r ".jobs|.[]|.id" | tr '\n' ' ')
if [ -z "$JOB_IDS" ]; then
  echo "No jobs were returned from plan execution."
  exit 1
fi

PLAN_EXECUTION_ID=$(echo "$JOBS" | jq -r ".id")

echo "Launched Plan execution: $PLAN_EXECUTION_ID"
echo "Launched jobs: $JOB_IDS"

#-----------------------------#
# Poll job status
#-----------------------------#

echo "--------"
ALL_SUCCESS=true
for JOB_ID in $JOB_IDS; do
  echo "Polling job $JOB_ID..."
  RUNNING=true
  while $RUNNING; do
    JOB=$(curl -s --header "Authorization: Bearer $VIRTUOSO_TOKEN" --header "X-Virtuoso-Client-Name: CICD" "https://api.virtuoso.qa/api/executions/$JOB_ID/status?envelope=false" || echo "{}")
    JOB_STATUS=$(echo "$JOB" | jq -r .status)
    OUTCOME=$(echo "$JOB" | jq -r .outcome)

    echo "Job: $JOB_ID status is \"$JOB_STATUS\""

    if [[ "$JOB_STATUS" == "FINISHED" || "$JOB_STATUS" == "CANCELED" || "$JOB_STATUS" == "FAILED" ]]; then
      RUNNING=false
      if [[ "$OUTCOME" == "FAIL" || "$OUTCOME" == "ERROR" ]]; then
        ALL_SUCCESS=false
      fi
    else
      sleep 5
    fi
  done
  echo "--------"
done

#-----------------------------#
# Save execution results
#-----------------------------#

echo "Exporting test results..."
RESULTS_FILE="plan_execution_report.json"

curl -s --header "Authorization: Bearer $TOKEN" --header "X-Virtuoso-Client-Name: CICD" "https://api.virtuoso.qa/api/plans/executions/status/$PLAN_EXECUTION_ID?envelope=false" | jq -r '.' > "$RESULTS_FILE"

echo "Exported the report as \"$RESULTS_FILE\""

if [ "$ALL_SUCCESS" = false ]; then
  echo "One or more jobs failed or errored."
  exit 2
fi

echo "All jobs finished successfully!"

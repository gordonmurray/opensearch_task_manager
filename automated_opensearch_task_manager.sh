#!/usr/bin/env bash

# Requirements: curl, jq
# Usage: ./opensearch_auto_task_manager.sh

# Configuration
HOST="https://localhost:9200"
USER="admin"
PASS="password"
THRESHOLD_MS=10000                    # 10 seconds in ms
THRESHOLD_NS=$((THRESHOLD_MS * 1000000))  # 10 sec in nanoseconds

while true; do
  echo "Checking for tasks running longer than ${THRESHOLD_MS} ms..."

  response=$(curl -sk -u "$USER:$PASS" "$HOST/_tasks?actions=*search&detailed=true")

  tasks=$(echo "$response" | jq -r --arg threshold "$THRESHOLD_NS" '
    .nodes[].tasks | to_entries[] |
    select(.value.cancellable == true and (.value.running_time_in_nanos|tonumber) >= ($threshold|tonumber)) |
    "\(.key) \(.value.running_time_in_nanos)"
  ')

  if [ -z "$tasks" ]; then
    echo "No long running tasks found."
  else
    timestamp=$(date +"%Y%m%d_%H%M%S")
    mkdir -p killed_tasks_logs
    echo "$tasks" | while read -r line; do
      task_id=$(echo "$line" | awk '{print $1}')
      running_ns=$(echo "$line" | awk '{print $2}')
      running_ms=$(( running_ns / 1000000 ))
      echo "Cancelling task $task_id (running ${running_ms} ms)..."

      cancel_output=$(curl -sk -u "$USER:$PASS" -XPOST "$HOST/_tasks/$task_id/_cancel")

      if echo "$cancel_output" | jq -e '.node_failures[]? | select(.caused_by.reason | test("not found"))' > /dev/null; then
        echo "Task $task_id already completed. Skipping."
      else
        echo "$cancel_output" | jq
        full_task=$(echo "$response" | jq ".nodes[].tasks[\"$task_id\"]")
        echo "$full_task" | jq > "killed_tasks_logs/${timestamp}_$task_id.json"
      fi
      echo "---"
    done
  fi
  echo "Sleeping for 5 seconds..."
  sleep 5
done

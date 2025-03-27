#!/usr/bin/env bash

# Requirements: curl, jq, fzf
# Usage: ./opensearch_task_manager.sh

# Configuration
HOST="https://localhost:9200"
USER="admin"
PASS="password"

cancel_tasks_loop() {
  while true; do
    # Fetch latest _tasks response
    response=$(curl -sk -u "$USER:$PASS" "$HOST/_tasks?actions=*search&detailed=true")

    mapfile -t tasks < <(echo "$response" | jq -r '
      .nodes[].tasks | to_entries[] | select(.value.cancellable == true) |
      "\(.key) | \(.value.action) | \(.value.description) | running: \(.value.running_time_in_nanos / 1000000 | floor) ms"
    ')

    if [ ${#tasks[@]} -eq 0 ]; then
      echo -e "\nNo cancellable search tasks found."
      sleep 5
      return
    fi

    selected=$(printf "%s\n" "${tasks[@]}" | \
      fzf --multi \
          --preview='echo {} | fold -s -w $(tput cols)' \
          --preview-window=wrap \
          --header="Select tasks to cancel (Tab to select, Enter to confirm, Esc to skip)" \
          --bind ctrl-a:toggle-all)

    if [ -z "$selected" ]; then
      echo -e "\nNo tasks selected. Returning to main loop..."
      return
    fi

    timestamp=$(date +"%Y%m%d_%H%M%S")
    mkdir -p killed_tasks_logs

    fresh_response=$(curl -sk -u "$USER:$PASS" "$HOST/_tasks?actions=*search&detailed=true")

    while IFS= read -r line; do
      task_id=$(echo "$line" | cut -d'|' -f1 | xargs)
      echo "Cancelling task $task_id..."
      cancel_output=$(curl -sk -u "$USER:$PASS" -XPOST "$HOST/_tasks/$task_id/_cancel")

      if echo "$cancel_output" | jq -e '.node_failures[]? | select(.caused_by.reason | test("not found"))' > /dev/null; then
        echo "Task $task_id already completed. Skipping."
      else
        echo "$cancel_output" | jq
        full_task=$(echo "$fresh_response" | jq ".nodes[].tasks[\"$task_id\"]")
        echo "$full_task" | jq > "killed_tasks_logs/${timestamp}_$task_id.json"
      fi
      echo "---"
    done <<< "$selected"
  done
}

while true; do
  clear
  echo -e "\nCurrent search thread pool status:"
  curl -sk -u "$USER:$PASS" "$HOST/_cat/thread_pool/search?v&h=node,active,queue,rejected"

  cancel_tasks_loop

  echo -e "\nReloading ..."
  sleep 2

done

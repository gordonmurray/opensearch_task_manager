#!/usr/bin/env bash

# Requirements: curl, jq, fzf
# Usage: ./opensearch_task_manager.sh

# Configuration
HOST="https://localhost:9200"
USER="admin"
PASS="password"

# Get current search thread pool status
echo -e "\nCurrent search thread pool status:"
curl -sk -u "$USER:$PASS" "$HOST/_cat/thread_pool/search?v&h=node,active,queue,rejected"

# Get list of cancellable search tasks
response=$(curl -sk -u "$USER:$PASS" "$HOST/_tasks?actions=*search&detailed=true")

# Extract tasks
mapfile -t tasks < <(echo "$response" | jq -r '
  .nodes[].tasks | to_entries[] | select(.value.cancellable == true) |
  "\(.key) | \(.value.action) | \(.value.description) | running: \(.value.running_time_in_nanos / 1000000 | floor) ms"
')

if [ ${#tasks[@]} -eq 0 ]; then
  echo "\nNo cancellable search tasks found."
  exit 0
fi

# Interactive selection via fzf with wrapped preview
selected=$(printf "%s\n" "${tasks[@]}" | \
  fzf --multi \
      --preview='echo {} | fold -s -w $(tput cols)' \
      --preview-window=wrap \
      --header="Select tasks to cancel (Tab to select, Enter to confirm)" \
      --bind ctrl-a:toggle-all)

if [ -z "$selected" ]; then
  echo "\nNo tasks selected. Exiting."
  exit 0
fi

# Cancel selected tasks, skip those that already completed
echo ""
while IFS= read -r line; do
  task_id=$(echo "$line" | cut -d'|' -f1 | xargs)
  echo "Cancelling task $task_id..."
  cancel_output=$(curl -sk -u "$USER:$PASS" -XPOST "$HOST/_tasks/$task_id/_cancel")

  if echo "$cancel_output" | jq -e '.node_failures[]? | select(.caused_by.reason | test("not found"))' > /dev/null; then
    echo "Task $task_id already completed. Skipping."
  else
    echo "$cancel_output" | jq
  fi
  echo "---"
done <<< "$selected"

# Final search thread pool status
echo -e "\nUpdated search thread pool status:"
curl -sk -u "$USER:$PASS" "$HOST/_cat/thread_pool/search?v&h=node,active,queue,rejected"

# Optional enhancement: count current active cancellable search tasks
count=$(echo "$response" | jq '[.nodes[].tasks | to_entries[] | select(.value.cancellable == true)] | length')
echo -e "\nCurrently active cancellable search tasks: $count"

# Optional: show which indices are involved in active tasks
echo -e "\nIndices involved in active search tasks:"
echo "$response" | jq -r '.nodes[].tasks | to_entries[] | select(.value.cancellable == true) | .value.description' \
  | grep -oE '\[.*?\]' | tr -d '[]' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort -u

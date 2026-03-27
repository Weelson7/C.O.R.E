#!/usr/bin/env bash
set -euo pipefail

# flap_detection.sh - detect and debounce flaky node health reports
# Usage: flap_detection.sh <node-id> <current-health> [state-file]

if [ "$#" -lt 2 ]; then
  echo "Usage: flap_detection.sh <node-id> <current-health> [state-file]" >&2
  exit 1
fi

node_id="$1"
current_health="$2"
state_file="${3:-data/state.json}"

FLAP_THRESHOLD=3        # require 3 consecutive health reports before triggering
FLAP_WINDOW=300         # detection window: 5 minutes
GRACE_PERIOD=60         # grace period after state change: 60s

# Initialize or retrieve flap counter for this node
jq --arg node "$node_id" \
   --arg health "$current_health" \
   --arg threshold "$FLAP_THRESHOLD" \
   '
   (.flapDetection //= {})
   | (.flapDetection[$node] // {
       lastState: null,
       changeCount: 0,
       lastChangeAt: 0,
       consecutiveReports: 0,
       confirmedAt: 0
     }) as $counter
   | if ($counter.lastState == $health) then
       ($counter.consecutiveReports + 1) as $new_count
       | if ($new_count >= ($threshold | tonumber)) then
           .flapDetection[$node] = ($counter + {
             lastState: $health,
             consecutiveReports: 0,
             confirmedAt: (now | floor)
           })
         else
           .flapDetection[$node] = ($counter + {
             lastState: $health,
             consecutiveReports: $new_count
           })
         end
     else
       .flapDetection[$node] = {
         lastState: $health,
         changeCount: ($counter.changeCount + 1),
         lastChangeAt: (now | floor),
         consecutiveReports: 1,
         confirmedAt: ($counter.confirmedAt // 0)
       }
     end
   ' "$state_file" >"${state_file}.tmp"

mv "${state_file}.tmp" "$state_file"

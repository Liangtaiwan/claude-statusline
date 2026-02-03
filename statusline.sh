#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract information from JSON
model_name=$(echo "$input" | jq -r '.model.display_name')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

# ============================================================================
# Usage Limit / Reset Time (cached ccusage call)
# ============================================================================

CACHE_FILE="/tmp/claude-usage-cache.json"
CACHE_TTL=60  # Refresh every 60 seconds
MSG_LIMIT=225  # Messages per 5hr window (Team/Max 5x: 225, Pro: 45, Max 20x: 900)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

reset_info=""

# Helper: Convert ISO timestamp to epoch (macOS/Linux compatible)
# Note: Timestamps ending in Z are UTC
to_epoch() {
    local ts="$1"
    local stripped="${ts%%.*}"  # Remove .000Z or similar
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: use date -j -f with -u for UTC timestamps
        date -j -u -f "%Y-%m-%dT%H:%M:%S" "$stripped" "+%s" 2>/dev/null || echo ""
    else
        # Linux: date -d handles ISO 8601 with Z suffix natively
        date -d "${ts}" "+%s" 2>/dev/null || echo ""
    fi
}

# Check if cache is fresh
cache_fresh=false
if [ -f "$CACHE_FILE" ]; then
    cache_age=$(($(date +%s) - $(stat -f%m "$CACHE_FILE" 2>/dev/null || stat -c%Y "$CACHE_FILE" 2>/dev/null || echo 0)))
    [ "$cache_age" -lt "$CACHE_TTL" ] && cache_fresh=true
fi

# Refresh cache if stale (background to avoid blocking)
if [ "$cache_fresh" = false ] && command -v jq >/dev/null 2>&1; then
    (
        blocks_output=$(npx ccusage@latest blocks --json 2>/dev/null || ccusage blocks --json 2>/dev/null)
        if [ -n "$blocks_output" ]; then
            echo "$blocks_output" > "$CACHE_FILE"
        fi
    ) &
fi

# Parse cached data if available
if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
    active_block=$(jq -c '.blocks[] | select(.isActive == true)' "$CACHE_FILE" 2>/dev/null | head -n1)
    if [ -n "$active_block" ]; then
        reset_time_str=$(echo "$active_block" | jq -r '.usageLimitResetTime // .endTime // empty')
        start_time_str=$(echo "$active_block" | jq -r '.startTime // empty')
        msg_count=$(echo "$active_block" | jq -r '.entries // 0')

        if [ -n "$reset_time_str" ] && [ -n "$start_time_str" ]; then
            start_sec=$(to_epoch "$start_time_str")
            end_sec=$(to_epoch "$reset_time_str")
            now_sec=$(date +%s)

            if [ -n "$start_sec" ] && [ -n "$end_sec" ]; then
                total=$(( end_sec - start_sec ))
                (( total < 1 )) && total=1
                elapsed=$(( now_sec - start_sec ))
                (( elapsed < 0 )) && elapsed=0
                (( elapsed > total )) && elapsed=$total
                session_pct=$(( elapsed * 100 / total ))

                remaining=$(( end_sec - now_sec ))
                (( remaining < 0 )) && remaining=0

                rh=$(( remaining / 3600 ))
                rm=$(( (remaining % 3600) / 60 ))

                # Only show if there's actual time remaining
                if (( remaining > 60 )); then
                    reset_info=" ${GRAY}⏱ ${rh}h${rm}m (${msg_count}/${MSG_LIMIT})${NC}"
                fi
            fi
        fi
    fi
fi

# Extract context percentage (available since Claude Code 2.1.6)
context_percent=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d'.' -f1)

# Build context progress bar (20 chars wide)
bar_width=15
filled=$((context_percent * bar_width / 100))
empty=$((bar_width - filled))
bar=""
for ((i = 0; i < filled; i++)); do bar+="█"; done
for ((i = 0; i < empty; i++)); do bar+="░"; done

# Extract cost information (2 decimal places for cleaner display)
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
[ "$session_cost" != "empty" ] && session_cost=$(printf "%.2f" "$session_cost") || session_cost=""

# Get directory name (basename)
dir_name=$(basename "$current_dir")

# Change to the current directory to get git info
cd "$current_dir" 2>/dev/null || cd /

# Get git branch (file stats now shown natively in input line)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git branch --show-current 2>/dev/null || echo "detached")
  git_info=" ${YELLOW}${branch}${NC}"
else
  git_info=""
fi

# Add session cost to reset_info if available
if [ -n "$session_cost" ] && [ "$session_cost" != "null" ] && [ "$session_cost" != "empty" ] && [ -n "$reset_info" ]; then
  reset_info=" ${GRAY}\$${session_cost}${NC}${reset_info}"
fi

# Build context bar display
context_info="${GRAY}${bar}${NC} ${context_percent}%"

# Line 1: Existing bash output (context, reset+cost, git, dir, model)
line1="${context_info}${reset_info}${git_info:+ ${GRAY}|${NC}}${git_info} ${GRAY}|${NC} ${BLUE}${dir_name}${NC} ${GRAY}|${NC} ${CYAN}${model_name}${NC}"

# Line 2: Tool/agent/todo status from Rust binary
line2=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    # Extract session ID (UUID) from transcript path for skill-status lookup
    session_id=$(echo "$transcript_path" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    line2=$(~/.claude/bin/claude-status "$transcript_path" "$session_id" 2>/dev/null)
fi

# Output the status lines
if [ -n "$line2" ]; then
    echo -e "${line1}\n${line2}"
else
    echo -e "${line1}"
fi

#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract information from JSON
model_name=$(echo "$input" | jq -r '.model.display_name')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')

# Extract cost, duration, and line changes from JSON
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# ============================================================================
# Usage Limit / Reset Time
# Parses rate limit error messages to find the fixed 5h window schedule.
# One reference epoch is enough to predict all future windows.
# ============================================================================

reset_info=""
MSG_LIMIT=225  # Max 5x: 225, Pro: 45, Max 20x: 900
RESET_REF_CACHE="$HOME/.claude/cache/claude-reset-ref"
now_sec=$(date +%s)

# Convert "9pm"→21, "6am"→6, "12am"→0, "12pm"→12
_hour_from_str() {
    local s="$1" h
    h=$(echo "$s" | grep -oE '[0-9]+')
    if echo "$s" | grep -qi 'pm'; then
        [ "$h" != "12" ] && h=$((h + 12))
    else
        [ "$h" = "12" ] && h=0
    fi
    echo "$h"
}

# Scan all transcripts for rate limit errors, extract most recent reset epoch
_scan_reset_ref() {
    local best_ts=0 best_epoch=0
    local line err_sec time_str tz hour date_str epoch day_offset

    while IFS= read -r line; do
        local ts text
        ts=$(echo "$line" | jq -r '.timestamp // empty' 2>/dev/null)
        text=$(echo "$line" | jq -r '.message.content[0].text // empty' 2>/dev/null)
        echo "$text" | grep -qi "resets [0-9]" || continue

        local stripped="${ts%%.*}"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            err_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$stripped" "+%s" 2>/dev/null)
        else
            err_sec=$(date -d "${ts}" "+%s" 2>/dev/null)
        fi
        [ -z "$err_sec" ] || [ "$err_sec" -le "$best_ts" ] && continue

        time_str=$(echo "$text" | grep -oiE '[0-9]+[ap]m' | head -1)
        tz=$(echo "$text" | grep -oE '\([^)]+\)' | tr -d '()' | head -1)
        [ -z "$time_str" ] || [ -z "$tz" ] && continue

        hour=$(_hour_from_str "$time_str")

        for day_offset in 0 1; do
            if [[ "$OSTYPE" == "darwin"* ]]; then
                date_str=$(TZ="$tz" date -j -r "$err_sec" -v+${day_offset}d "+%Y/%m/%d" 2>/dev/null)
                epoch=$(TZ="$tz" date -j -f "%Y/%m/%d %H:%M" "$date_str $hour:00" "+%s" 2>/dev/null)
            else
                epoch=$(TZ="$tz" date -d "$(date -u -d @"$err_sec" +%Y-%m-%d) + $day_offset days $hour:00" "+%s" 2>/dev/null)
            fi
            if [ -n "$epoch" ] && [ "$epoch" -gt "$err_sec" ] && [ "$epoch" -le "$((err_sec + 5*3600))" ]; then
                best_ts="$err_sec"; best_epoch="$epoch"; break
            fi
        done
    done < <(grep -rh '"isApiErrorMessage":true' ~/.claude/projects --include="*.jsonl" 2>/dev/null)

    [ "$best_epoch" -gt 0 ] && echo "$best_epoch"
}

# Load reference reset epoch (scan transcripts if missing)
ref_epoch=0
if [ -f "$RESET_REF_CACHE" ]; then
    ref_epoch=$(cat "$RESET_REF_CACHE" 2>/dev/null)
fi

if [ -z "$ref_epoch" ] || [ "$ref_epoch" -le 0 ] 2>/dev/null; then
    # Run scan in background; result appears on next statusline render
    ( result=$(_scan_reset_ref); [ -n "$result" ] && echo "$result" > "$RESET_REF_CACHE" ) &
fi

# Derive current window reset from reference (advance by 5h intervals)
reset_sec=""
window_start=0
if [ -n "$ref_epoch" ] && [ "$ref_epoch" -gt 0 ] 2>/dev/null; then
    reset_sec="$ref_epoch"
    while [ "$reset_sec" -le "$now_sec" ] 2>/dev/null; do
        reset_sec=$(( reset_sec + 5*3600 ))
    done
    window_start=$(( reset_sec - 5*3600 ))
fi

# Message count: real user inputs from all transcripts (cached background scan)
MSG_COUNT_CACHE="/tmp/claude-msg-count"
MSG_CACHE_TTL=15
msg_count=0

if [ -f "$MSG_COUNT_CACHE" ]; then
    cache_age=$((now_sec - $(stat -f%m "$MSG_COUNT_CACHE" 2>/dev/null || stat -c%Y "$MSG_COUNT_CACHE" 2>/dev/null || echo 0)))
    if [ "$cache_age" -lt "$MSG_CACHE_TTL" ]; then
        msg_count=$(cat "$MSG_COUNT_CACHE" 2>/dev/null)
    fi
fi

if [ -z "$msg_count" ] || [ "$msg_count" = "0" ] && [ "$window_start" -gt 0 ] 2>/dev/null; then
    # Background: count user messages with string content (real inputs, not tool_results)
    # across all sessions including subagents
    (
        if [[ "$OSTYPE" == "darwin"* ]]; then
            co=$(date -j -u -r "$window_start" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)
        else
            co=$(date -u -d "@$window_start" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)
        fi
        [ -z "$co" ] && exit
        c=0
        for f in $(find ~/.claude/projects -name "*.jsonl" -mmin -360 2>/dev/null); do
            n=$(grep '"type":"user"' "$f" 2>/dev/null | grep -v '"tool_result"' | \
                awk -v cutoff="$co" -F'"timestamp":"' '{split($2,a,"\""); if(a[1] > cutoff) print}' | wc -l)
            c=$((c + n))
        done
        echo "$c" > "$MSG_COUNT_CACHE"
    ) &
fi
msg_count=${msg_count:-0}

# Format
if [ -n "$reset_sec" ] && [ "$reset_sec" -gt 0 ] 2>/dev/null; then
    remaining=$(( reset_sec - now_sec ))
    (( remaining < 0 )) && remaining=0
    rh=$(( remaining / 3600 ))
    rm=$(( (remaining % 3600) / 60 ))
    if (( remaining > 60 )); then
        reset_info=" ${GRAY}⏱ ${rh}h${rm}m (${msg_count}/${MSG_LIMIT})${NC}"
    else
        reset_info=" ${GRAY}(${msg_count}/${MSG_LIMIT})${NC}"
    fi
elif [ "$msg_count" -gt 0 ] 2>/dev/null; then
    reset_info=" ${GRAY}(${msg_count}/${MSG_LIMIT})${NC}"
fi

# Extract context percentage (available since Claude Code 2.1.6)
context_percent=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d'.' -f1)

# Build context progress bar (15 chars wide)
bar_width=15
filled=$((context_percent * bar_width / 100))
empty=$((bar_width - filled))
bar=""
for ((i = 0; i < filled; i++)); do bar+="█"; done
for ((i = 0; i < empty; i++)); do bar+="░"; done

# Format session cost
cost_info=""
if [ -n "$session_cost" ] && [ "$session_cost" != "null" ] && [ "$session_cost" != "empty" ]; then
    session_cost=$(printf "%.2f" "$session_cost")
    cost_info=" ${GRAY}\$${session_cost}${NC}"
fi

# Get directory name (basename)
dir_name=$(basename "$current_dir")

# Change to the current directory to get git info
cd "$current_dir" 2>/dev/null || cd /

# Get git branch
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git branch --show-current 2>/dev/null || echo "detached")
  git_info=" ${YELLOW}${branch}${NC}"
else
  git_info=""
fi

# Build context bar display
context_info="${GRAY}${bar}${NC} ${context_percent}%"

# Line 1: Context, cost, duration, lines, usage limit, git, dir, model
line1="${context_info}${cost_info}${reset_info}${git_info:+ ${GRAY}|${NC}}${git_info} ${GRAY}|${NC} ${BLUE}${dir_name}${NC} ${GRAY}|${NC} ${CYAN}${model_name}${NC}"

# Line 2: Tool/agent/todo status from Rust binary
line2=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    line2=$(~/.claude/bin/claude-status "$transcript_path" "$session_id" 2>/dev/null)
fi

# Output the status lines
if [ -n "$line2" ]; then
    echo -e "${line1}\n${line2}"
else
    echo -e "${line1}"
fi

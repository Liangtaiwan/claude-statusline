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
# Parses rate limit error messages to find the 5h window schedule.
# Rescans periodically since the window schedule can shift.
# ============================================================================

reset_info=""
RESET_REF_CACHE="$HOME/.claude/cache/claude-reset-ref"
TOKEN_BUDGET_CACHE="$HOME/.claude/cache/claude-token-budget"
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

    [ "$best_epoch" -gt 0 ] && echo "$best_epoch $best_ts"
}

# Compute token budget: sum output_tokens from window_start to error_timestamp
_compute_token_budget() {
    local err_ts="$1" reset_epoch="$2"
    local ws=$((reset_epoch - 5*3600))
    local co_start co_end
    if [[ "$OSTYPE" == "darwin"* ]]; then
        co_start=$(date -j -u -r "$ws" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)
        co_end=$(date -j -u -r "$err_ts" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)
    else
        co_start=$(date -u -d "@$ws" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)
        co_end=$(date -u -d "@$err_ts" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)
    fi
    [ -z "$co_start" ] || [ -z "$co_end" ] && return
    local total=0
    for f in $(find ~/.claude/projects -name "*.jsonl" 2>/dev/null); do
        local n
        n=$(grep '"type":"assistant"' "$f" 2>/dev/null | \
            awk -v s="$co_start" -v e="$co_end" -F'"timestamp":"' '{split($2,a,"\""); if(a[1]>s && a[1]<e) print}' | \
            grep -oE '"output_tokens":[0-9]+' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
        total=$((total + n))
    done
    [ "$total" -gt 0 ] && echo "$total"
}

# Load reference reset epoch (rescan periodically to catch schedule shifts)
REF_CACHE_TTL=60
ref_epoch=0
ref_stale=1
if [ -f "$RESET_REF_CACHE" ]; then
    ref_epoch=$(cat "$RESET_REF_CACHE" 2>/dev/null)
    ref_age=$((now_sec - $(stat -f%m "$RESET_REF_CACHE" 2>/dev/null || stat -c%Y "$RESET_REF_CACHE" 2>/dev/null || echo 0)))
    [ "$ref_age" -lt "$REF_CACHE_TTL" ] && ref_stale=0
fi

if [ "$ref_stale" = "1" ]; then
    # Background rescan; updates cache and computes token budget if new error found
    (
        result=$(_scan_reset_ref)
        [ -z "$result" ] && exit
        new_epoch=$(echo "$result" | awk '{print $1}')
        err_ts=$(echo "$result" | awk '{print $2}')
        echo "$new_epoch" > "$RESET_REF_CACHE"
        # Recompute budget if this is a new reference
        old_epoch=$(cat "$TOKEN_BUDGET_CACHE" 2>/dev/null | awk '{print $2}')
        if [ "$new_epoch" != "$old_epoch" ] && [ -n "$err_ts" ] && [ "$err_ts" -gt 0 ]; then
            budget=$(_compute_token_budget "$err_ts" "$new_epoch")
            [ -n "$budget" ] && echo "$budget $new_epoch" > "$TOKEN_BUDGET_CACHE"
        fi
    ) &
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

# Usage percentage: output_tokens in current window vs budget from last rate limit
USAGE_TOKENS_CACHE="/tmp/claude-usage-tokens"
USAGE_CACHE_TTL=15
usage_tokens=0
token_budget=0

# Load token budget (from last rate-limit calibration)
[ -f "$TOKEN_BUDGET_CACHE" ] && token_budget=$(awk '{print $1}' "$TOKEN_BUDGET_CACHE" 2>/dev/null)
token_budget=${token_budget:-0}

# Load current window output_tokens (stale-while-revalidate)
usage_stale=1
if [ -f "$USAGE_TOKENS_CACHE" ]; then
    usage_tokens=$(cat "$USAGE_TOKENS_CACHE" 2>/dev/null)
    cache_age=$((now_sec - $(stat -f%m "$USAGE_TOKENS_CACHE" 2>/dev/null || stat -c%Y "$USAGE_TOKENS_CACHE" 2>/dev/null || echo 0)))
    [ "$cache_age" -lt "$USAGE_CACHE_TTL" ] && usage_stale=0
fi

if [ "$usage_stale" = "1" ] && [ "$window_start" -gt 0 ] 2>/dev/null; then
    # Background: sum output_tokens from all assistant messages in current window
    (
        if [[ "$OSTYPE" == "darwin"* ]]; then
            co=$(date -j -u -r "$window_start" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)
        else
            co=$(date -u -d "@$window_start" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)
        fi
        [ -z "$co" ] && exit
        total=0
        for f in $(find ~/.claude/projects -name "*.jsonl" -mmin -360 2>/dev/null); do
            n=$(grep '"type":"assistant"' "$f" 2>/dev/null | \
                awk -v cutoff="$co" -F'"timestamp":"' '{split($2,a,"\""); if(a[1] > cutoff) print}' | \
                grep -oE '"output_tokens":[0-9]+' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
            total=$((total + n))
        done
        echo "$total" > "$USAGE_TOKENS_CACHE"
    ) &
fi
usage_tokens=${usage_tokens:-0}

# Format
if [ -n "$reset_sec" ] && [ "$reset_sec" -gt 0 ] 2>/dev/null; then
    remaining=$(( reset_sec - now_sec ))
    (( remaining < 0 )) && remaining=0
    rh=$(( remaining / 3600 ))
    rm=$(( (remaining % 3600) / 60 ))
    use_info=""
    if [ "$token_budget" -gt 0 ] && [ "$usage_tokens" -gt 0 ]; then
        use_pct=$((usage_tokens * 100 / token_budget))
        [ "$use_pct" -gt 100 ] && use_pct=100
        use_info=" (${use_pct}%)"
    fi
    if (( remaining > 60 )); then
        reset_info=" ${GRAY}⏱ ${rh}h${rm}m${use_info}${NC}"
    else
        reset_info=" ${GRAY}${use_info:-resetting}${NC}"
    fi
elif [ "$usage_tokens" -gt 0 ] && [ "$token_budget" -gt 0 ]; then
    use_pct=$((usage_tokens * 100 / token_budget))
    [ "$use_pct" -gt 100 ] && use_pct=100
    reset_info=" ${GRAY}(${use_pct}%)${NC}"
fi

# Context percentage using effective window (200K - 20K output reservation = 180K)
# See: github.com/anthropics/claude-code/issues/18944
ctx_window=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$ctx_window" = "null" ] && ctx_window=200000
ctx_effective=$((ctx_window - 20000))
ctx_input=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
ctx_cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
ctx_cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
[ "$ctx_input" = "null" ] && ctx_input=0
[ "$ctx_cache_create" = "null" ] && ctx_cache_create=0
[ "$ctx_cache_read" = "null" ] && ctx_cache_read=0
ctx_tokens=$((ctx_input + ctx_cache_create + ctx_cache_read))
if [ "$ctx_tokens" -gt 0 ] && [ "$ctx_effective" -gt 0 ]; then
    context_percent=$((ctx_tokens * 100 / ctx_effective))
    [ "$context_percent" -gt 100 ] && context_percent=100
else
    context_percent=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d'.' -f1)
fi

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

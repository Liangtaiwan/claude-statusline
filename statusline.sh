#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract all fields from JSON in a single jq call (pipe delimiter avoids empty-field collapse)
IFS='|' read -r model_name current_dir transcript_path session_id session_cost context_percent \
  effort_level fh_pct fh_reset sd_pct sd_reset lines_added lines_removed \
  <<< "$(echo "$input" | jq -r '[
    .model.display_name,
    .workspace.current_dir,
    (.transcript_path // ""),
    (.session_id // ""),
    (.cost.total_cost_usd // ""),
    ((.context_window.used_percentage // 0) | floor | tostring),
    (.effort.level // ""),
    ((.rate_limits.five_hour.used_percentage // 0) | floor | tostring),
    ((.rate_limits.five_hour.resets_at // "") | tostring),
    ((.rate_limits.seven_day.used_percentage // 0) | floor | tostring),
    ((.rate_limits.seven_day.resets_at // "") | tostring),
    ((.cost.total_lines_added // 0) | tostring),
    ((.cost.total_lines_removed // 0) | tostring)
  ] | join("|")')"

# Colors
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
# Catppuccin tiers (match the Rust line-2 palette)
GREEN='\033[38;2;166;227;161m'
PEACH='\033[38;2;250;179;135m'
RED='\033[38;2;243;139;168m'
NC='\033[0m' # No Color

now_sec=$(date +%s)

# Color a 0-100 utilization: dim < 75, peach 75-89, red >= 90
pct_color() {
    local p="$1"
    if [ "$p" -ge 90 ] 2>/dev/null; then printf '%s' "$RED"
    elif [ "$p" -ge 75 ] 2>/dev/null; then printf '%s' "$PEACH"
    else printf '%s' "$GRAY"
    fi
}

# --- Rate limits (native, from payload rate_limits.{five_hour,seven_day}) -----
# Claude Code provides utilization + reset epoch directly; no OAuth API, keychain,
# curl, caching, or transcript-grep fallback needed anymore.
rate_info=""
if [ -n "$fh_reset" ] || [ -n "$sd_reset" ]; then
    reset_str=""
    if [ -n "$fh_reset" ] && [ "$fh_reset" -gt "$now_sec" ] 2>/dev/null; then
        remaining=$(( fh_reset - now_sec ))
        rh=$(( remaining / 3600 ))
        rm=$(( (remaining % 3600) / 60 ))
        reset_str="${GRAY}⏱ ${rh}h${rm}m${NC} "
    fi
    fh_c=$(pct_color "$fh_pct")
    sd_c=$(pct_color "$sd_pct")
    rate_info=" ${reset_str}${fh_c}5h ${fh_pct}%${NC} ${GRAY}·${NC} ${sd_c}7d ${sd_pct}%${NC}"
fi

# Build context progress bar (15 chars wide)
full="███████████████"
empty_str="░░░░░░░░░░░░░░░"
bar_width=15
filled=$((context_percent * bar_width / 100))
empty=$((bar_width - filled))
bar="${full:0:filled}${empty_str:0:empty}"
context_info="${GRAY}${bar}${NC} ${context_percent}%"

# Session cost
cost_info=""
if [ -n "$session_cost" ] && [ "$session_cost" != "null" ] && [ "$session_cost" != "empty" ]; then
    session_cost=$(printf "%.2f" "$session_cost")
    cost_info=" ${GRAY}\$${session_cost}${NC}"
fi

# Lines changed this session (cost.total_lines_added / total_lines_removed)
lines_info=""
if [ "${lines_added:-0}" -gt 0 ] 2>/dev/null || [ "${lines_removed:-0}" -gt 0 ] 2>/dev/null; then
    lines_info=" ${GREEN}+${lines_added}${NC} ${RED}-${lines_removed}${NC}"
fi

# Directory name and git branch (falls back to short SHA when detached)
dir_name="${current_dir##*/}"
branch=$(git -C "$current_dir" symbolic-ref --short -q HEAD 2>/dev/null \
         || git -C "$current_dir" rev-parse --short HEAD 2>/dev/null)
if [ -n "$branch" ]; then
    git_info=" ${YELLOW}${branch}${NC}"
else
    git_info=""
fi

# Model + effort (effort.level is the current session's reasoning setting)
model_info="${CYAN}${model_name}${NC}"
if [ -n "$effort_level" ]; then
    case "$effort_level" in
        max)         eff_c="$RED" ;;
        high|xhigh)  eff_c="$PEACH" ;;
        *)           eff_c="$GRAY" ;;
    esac
    model_info="${model_info} ${GRAY}·${NC} ${eff_c}${effort_level}${NC}"
fi

# Line 1: context, cost, lines, rate limits, git, dir, model + effort
line1="${context_info}${cost_info}${lines_info}${rate_info}${git_info:+ ${GRAY}|${NC}}${git_info} ${GRAY}|${NC} ${BLUE}${dir_name}${NC} ${GRAY}|${NC} ${model_info}"

# Line 2: tool/agent/todo status from the Rust binary (transcript parsing)
line2=""
if [ -n "$transcript_path" ]; then
    line2=$(~/.claude/bin/claude-status "$transcript_path" "$session_id" 2>/dev/null)
fi

# Output the status lines
if [ -n "$line2" ]; then
    echo -e "${line1}\n${line2}"
else
    echo -e "${line1}"
fi

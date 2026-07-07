#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract all fields from JSON in a single jq call (pipe delimiter avoids empty-field collapse)
IFS='|' read -r model_name current_dir transcript_path session_id session_cost context_percent \
  effort_level fh_pct fh_reset sd_pct sd_reset \
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
    ((.rate_limits.seven_day.resets_at // "") | tostring)
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

# Format a countdown to an epoch target: "0h2m", or "6d5h" once >= 1 day.
fmt_countdown() {
    local target="$1"
    [ -n "$target" ] && [ "$target" -gt "$now_sec" ] 2>/dev/null || return
    local rem=$(( target - now_sec ))
    local d=$(( rem / 86400 )) h=$(( (rem % 86400) / 3600 )) m=$(( (rem % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"; else printf '%dh%dm' "$h" "$m"; fi
}

# --- Rate limits (native, from payload rate_limits.{five_hour,seven_day}) -----
# Show reset countdown + utilization for each window: "⏱ 0h2m (11%) · 20h3m (60%)"
rate_info=""
if [ -n "$fh_reset" ] || [ -n "$sd_reset" ]; then
    fh_cd=$(fmt_countdown "$fh_reset")
    sd_cd=$(fmt_countdown "$sd_reset")
    fh_c=$(pct_color "$fh_pct")
    sd_c=$(pct_color "$sd_pct")
    rate_info=" ${GRAY}⏱${NC} ${fh_c}${fh_cd:+$fh_cd }(${fh_pct}%)${NC} ${GRAY}·${NC} ${sd_c}${sd_cd:+$sd_cd }(${sd_pct}%)${NC}"
fi

# Build context progress bar (15 chars wide)
full="███████████████"
empty_str="░░░░░░░░░░░░░░░"
bar_width=15
filled=$((context_percent * bar_width / 100))
empty=$((bar_width - filled))
bar="${full:0:filled}${empty_str:0:empty}"
context_info="${GRAY}${bar}${NC} ${context_percent}%"

# Session cost: $3.48
cost_info=""
if [ -n "$session_cost" ] && [ "$session_cost" != "null" ] && [ "$session_cost" != "empty" ]; then
    session_cost=$(printf "%.2f" "$session_cost")
    cost_info=" ${GRAY}\$${session_cost}${NC}"
fi

# Directory name
dir_name="${current_dir##*/}"
dir_seg="${BLUE}${dir_name}${NC}"

# Git branch + working-tree diff stats: chezmoi (3 files +45 -12)
branch=$(git -C "$current_dir" symbolic-ref --short -q HEAD 2>/dev/null \
         || git -C "$current_dir" rev-parse --short HEAD 2>/dev/null)
git_seg=""
if [ -n "$branch" ]; then
    git_seg="${YELLOW}${branch}${NC}"
    stats=$(git -C "$current_dir" diff HEAD --numstat 2>/dev/null)
    if [ -n "$stats" ]; then
        n_files=$(printf '%s\n' "$stats" | grep -c '^')
        n_add=$(printf '%s\n' "$stats" | awk '{a+=$1} END{print a+0}')
        n_del=$(printf '%s\n' "$stats" | awk '{d+=$2} END{print d+0}')
        file_word="files"; [ "$n_files" -eq 1 ] && file_word="file"
        git_seg="${git_seg} ${GRAY}(${n_files} ${file_word} ${GREEN}+${n_add} ${RED}-${n_del}${GRAY})${NC}"
    fi
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

# Line 1: context, cost, rate limits, dir, git (branch + stats), model + effort
sep=" ${GRAY}|${NC} "
line1="${context_info}${cost_info}${rate_info}${sep}${dir_seg}${git_seg:+${sep}${git_seg}}${sep}${model_info}"

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

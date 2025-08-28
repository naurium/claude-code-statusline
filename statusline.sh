#!/bin/bash

# Memory leak fixes: Add process tracking and cleanup
BACKGROUND_PIDS=()
LOCKFILE="/tmp/ccusage_update.lock"
MAX_CONCURRENT_UPDATES=1

# Cleanup function to kill background processes and remove lockfile
cleanup() {
    for pid in "${BACKGROUND_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
    done
    rm -f "$LOCKFILE"
    # Clean up old session files (older than 24 hours)
    find /tmp -name "claude_processing_start_*.timestamp" -mtime +1 -delete 2>/dev/null
}

# Set up signal handlers for proper cleanup
trap cleanup EXIT SIGINT SIGTERM

# Read JSON input from stdin (limit to prevent memory issues)
input=$(head -c 100000)

# Debug logging (uncomment to debug)
# echo "$(date): Input received" >> /Users/naurium/.claude/statusline-debug.log
# echo "$input" >> /Users/naurium/.claude/statusline-debug.log

# Extract data from JSON input
model_name=$(echo "$input" | grep -o '"display_name":"[^"]*"' | sed 's/"display_name":"\([^"]*\)"/\1/' | head -1)
model_name=${model_name:-"Opus 4.1"}

transcript_path=$(echo "$input" | grep -o '"transcript_path":"[^"]*"' | sed 's/"transcript_path":"\([^"]*\)"/\1/' | head -1)
session_id=$(echo "$input" | grep -o '"session_id":"[^"]*"' | sed 's/"session_id":"\([^"]*\)"/\1/' | head -1)

current_dir=$(echo "$input" | grep -o '"current_dir":"[^"]*"' | sed 's/"current_dir":"\([^"]*\)"/\1/' | head -1)
current_dir=${current_dir:-$(pwd)}

# Processing time tracking file - stores timestamp when user sends a message
# CRITICAL: Each session must have its own unique timestamp file!
if [ -z "$session_id" ]; then
    # If no session_id, generate one from transcript_path or use process ID as fallback
    if [ -n "$transcript_path" ]; then
        # Extract a unique identifier from transcript path
        session_id=$(echo "$transcript_path" | sed 's/.*\/\([^\/]*\)\.json$/\1/')
    else
        # Last resort: use process ID to ensure uniqueness
        session_id="pid_$$"
    fi
fi

PROCESSING_TIME_FILE="/tmp/claude_processing_start_${session_id}.timestamp"

# Hook event name to detect when processing starts
hook_event=$(echo "$input" | grep -o '"hook_event_name":"[^"]*"' | sed 's/"hook_event_name":"\([^"]*\)"/\1/' | head -1)

# Check if this is a UserPromptSubmit event (user just sent a message)
if [ "$hook_event" = "UserPromptSubmit" ]; then
    # Record the current timestamp when user submits a prompt
    date +%s > "$PROCESSING_TIME_FILE"
fi

# Calculate processing time if we have a start timestamp
# IMPORTANT: Only use the session-specific file, no dangerous fallbacks!
processing_time_display=""
if [ -f "$PROCESSING_TIME_FILE" ]; then
    start_time=$(cat "$PROCESSING_TIME_FILE")
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    
    # Format elapsed time: 36s, 1m23s, 1h24m, 1d23h
    if [ "$elapsed" -ge 0 ]; then
        if [ "$elapsed" -lt 60 ]; then
            # Less than a minute - show just seconds
            processing_time_display="${elapsed}s"
        elif [ "$elapsed" -lt 3600 ]; then
            # Less than an hour - show XmYs format
            minutes=$((elapsed / 60))
            seconds=$((elapsed % 60))
            processing_time_display="${minutes}m${seconds}s"
        elif [ "$elapsed" -lt 86400 ]; then
            # Less than a day - show XhYm format
            hours=$((elapsed / 3600))
            minutes=$(((elapsed % 3600) / 60))
            processing_time_display="${hours}h${minutes}m"
        else
            # More than a day - show XdYh format
            days=$((elapsed / 86400))
            hours=$(((elapsed % 86400) / 3600))
            processing_time_display="${days}d${hours}h"
        fi
    else
        processing_time_display="..."
    fi
else
    # No timer file - show waiting indicator
    processing_time_display="..."
fi

# Cache file for ccusage blocks data (5 minute cache)
BLOCKS_CACHE="/tmp/ccusage_blocks_cache.json"
DAILY_CACHE="/tmp/ccusage_daily_cache.json"
ERROR_LOG="/tmp/statusline-errors.log"
CACHE_AGE=300  # 5 minutes

# Rotate error log if it gets too large (>10MB)
if [ -f "$ERROR_LOG" ]; then
    log_size=$(stat -f%z "$ERROR_LOG" 2>/dev/null || echo 0)
    if [ "$log_size" -gt 10485760 ]; then
        mv "$ERROR_LOG" "$ERROR_LOG.old"
        touch "$ERROR_LOG"
    fi
fi

# Check if ccusage is available
CCUSAGE_AVAILABLE=false
if command -v ccusage >/dev/null 2>&1; then
    CCUSAGE_AVAILABLE=true
elif command -v npx >/dev/null 2>&1; then
    # Check if ccusage is available via npx
    if npx ccusage --help >/dev/null 2>&1; then
        CCUSAGE_AVAILABLE=true
    fi
fi

# Function to update blocks cache with timeout and memory limit
update_blocks_cache() {
    if [ "$CCUSAGE_AVAILABLE" = true ]; then
        # Use timeout and memory limits to prevent runaway processes
        export NODE_OPTIONS="--max-old-space-size=512"
        if command -v ccusage >/dev/null 2>&1; then
            ccusage blocks --json 2>>"$ERROR_LOG" > "$BLOCKS_CACHE.tmp" && mv "$BLOCKS_CACHE.tmp" "$BLOCKS_CACHE"
        else
            npx ccusage blocks --json 2>>"$ERROR_LOG" > "$BLOCKS_CACHE.tmp" && mv "$BLOCKS_CACHE.tmp" "$BLOCKS_CACHE"
        fi
        unset NODE_OPTIONS
    else
        # Create empty cache to indicate ccusage is not available
        echo '{"blocks":[]}' > "$BLOCKS_CACHE"
    fi
}

# Function to update daily cache with timeout and memory limit
update_daily_cache() {
    if [ "$CCUSAGE_AVAILABLE" = true ]; then
        # Use timeout and memory limits to prevent runaway processes
        export NODE_OPTIONS="--max-old-space-size=512"
        if command -v ccusage >/dev/null 2>&1; then
            ccusage daily --json --since $(date +%Y%m%d) --until $(date +%Y%m%d) 2>>"$ERROR_LOG" > "$DAILY_CACHE.tmp" && mv "$DAILY_CACHE.tmp" "$DAILY_CACHE"
        else
            npx ccusage daily --json --since $(date +%Y%m%d) --until $(date +%Y%m%d) 2>>"$ERROR_LOG" > "$DAILY_CACHE.tmp" && mv "$DAILY_CACHE.tmp" "$DAILY_CACHE"
        fi
        unset NODE_OPTIONS
    else
        # Create empty cache to indicate ccusage is not available  
        echo '{"totals":{"totalCost":0}}' > "$DAILY_CACHE"
    fi
}

# Check if blocks cache needs update (with lock to prevent concurrent updates)
if [ ! -f "$BLOCKS_CACHE" ]; then
    update_blocks_cache
else
    cache_age=$(($(date +%s) - $(stat -f %m "$BLOCKS_CACHE" 2>/dev/null || echo 0)))
    if [ "$cache_age" -gt "$CACHE_AGE" ]; then
        # Use lockfile to prevent multiple simultaneous updates
        if mkdir "$LOCKFILE.blocks" 2>/dev/null; then
            (
                update_blocks_cache
                rmdir "$LOCKFILE.blocks" 2>/dev/null
            ) &
            BACKGROUND_PIDS+=($!)
        fi
    fi
fi

# Check if daily cache needs update (with lock to prevent concurrent updates)
if [ ! -f "$DAILY_CACHE" ]; then
    update_daily_cache
else
    cache_age=$(($(date +%s) - $(stat -f %m "$DAILY_CACHE" 2>/dev/null || echo 0)))
    if [ "$cache_age" -gt "$CACHE_AGE" ]; then
        # Use lockfile to prevent multiple simultaneous updates
        if mkdir "$LOCKFILE.daily" 2>/dev/null; then
            (
                update_daily_cache
                rmdir "$LOCKFILE.daily" 2>/dev/null
            ) &
            BACKGROUND_PIDS+=($!)
        fi
    fi
fi

# Parse cached ccusage blocks data for session info
if [ -f "$BLOCKS_CACHE" ]; then
    # Extract active block data with better error handling and timeout
    block_data=$(python3 -c "
import json, sys, traceback
import datetime

try:
    with open('$BLOCKS_CACHE', 'r') as f:
        data = json.load(f)
    
    # Find active block
    found_active = False
    for block in data.get('blocks', []):
        if block.get('isActive'):
            tokens = block.get('totalTokens', 0)
            cost = block.get('costUSD', 0)
            
            # Calculate session time
            try:
                start_time = block.get('startTime', '')
                if start_time:
                    # Handle both formats: with and without timezone
                    if start_time.endswith('Z'):
                        start = datetime.datetime.fromisoformat(start_time.replace('Z', '+00:00'))
                    else:
                        start = datetime.datetime.fromisoformat(start_time)
                    
                    now = datetime.datetime.now(datetime.timezone.utc)
                    duration = now - start
                    
                    # Ensure positive duration
                    if duration.total_seconds() >= 0:
                        hours = int(duration.total_seconds() // 3600)
                        minutes = int((duration.total_seconds() % 3600) // 60)
                    else:
                        hours = 0
                        minutes = 0
                else:
                    hours = 0
                    minutes = 0
            except Exception as time_err:
                print(f'Time calculation error: {time_err}', file=sys.stderr)
                hours = 0
                minutes = 0
            
            print(f'{tokens}|{cost:.2f}|{hours}|{minutes}')
            found_active = True
            break
    
    if not found_active:
        # No active block, try to get last non-gap block
        non_gap_blocks = [b for b in data.get('blocks', []) if not b.get('isGap', False)]
        if non_gap_blocks:
            last = non_gap_blocks[-1]
            tokens = last.get('totalTokens', 0)
            cost = last.get('costUSD', 0)
            print(f'{tokens}|{cost:.2f}|0|0')
        else:
            print('0|0.00|0|0')
            
except FileNotFoundError:
    print('Cache file not found', file=sys.stderr)
    print('0|0.00|0|0')
except json.JSONDecodeError as je:
    print(f'JSON decode error: {je}', file=sys.stderr)
    print('0|0.00|0|0')
except Exception as e:
    print(f'Unexpected error: {e}', file=sys.stderr)
    traceback.print_exc(file=sys.stderr)
    print('0|0.00|0|0')
" 2>>"$ERROR_LOG")
    
    # Parse the output
    IFS='|' read -r total_tokens session_cost hours minutes <<< "$block_data"
    
    # Default values if parsing fails
    total_tokens=${total_tokens:-0}
    session_cost=${session_cost:-0.00}
    hours=${hours:-0}
    minutes=${minutes:-0}
else
    # No cache, use defaults
    total_tokens=0
    session_cost=0.00
    hours=0
    minutes=0
fi

# Parse daily cost from ccusage daily
if [ -f "$DAILY_CACHE" ]; then
    daily_cost=$(python3 -c "
import json, sys

try:
    with open('$DAILY_CACHE', 'r') as f:
        data = json.load(f)
    totals = data.get('totals', {})
    cost = totals.get('totalCost', 0)
    print(f'{cost:.2f}')
except Exception as e:
    print(f'Error reading daily cache: {e}', file=sys.stderr)
    print('0.00')
" 2>>"$ERROR_LOG")
    daily_cost=${daily_cost:-0.00}
else
    daily_cost="0.00"
fi

# Get git branch
git_branch=$(cd "$current_dir" 2>/dev/null && git branch --show-current 2>/dev/null || echo "")
if [ -z "$git_branch" ]; then
    git_branch="none"
fi

# Get folder name
folder_name=$(basename "$current_dir")

# Format tokens for display with appropriate suffix
if [ "$total_tokens" -gt 0 ]; then
    if [ "$total_tokens" -ge 1000000000 ]; then
        # Billions
        tokens_b=$((total_tokens / 1000000000))
        tokens_display="${tokens_b}B"
    elif [ "$total_tokens" -ge 1000000 ]; then
        # Millions
        tokens_m=$((total_tokens / 1000000))
        tokens_display="${tokens_m}M"
    elif [ "$total_tokens" -ge 1000 ]; then
        # Thousands
        tokens_k=$((total_tokens / 1000))
        tokens_display="${tokens_k}k"
    else
        # Raw number
        tokens_display="${total_tokens}"
    fi
else
    tokens_display="0"
fi

# Format session time (compact format)
if [ "$hours" -gt 0 ] || [ "$minutes" -gt 0 ]; then
    if [ "$hours" -gt 0 ]; then
        if [ "$minutes" -gt 0 ]; then
            session_time="${hours}h${minutes}m"
        else
            session_time="${hours}h"
        fi
    else
        session_time="${minutes}m"
    fi
else
    session_time="0m"
fi

# Format session cost (rounded to nearest dollar)
if [ -n "$session_cost" ] && [ "$session_cost" != "0.00" ]; then
    # Round to nearest dollar, but show at least $1 if there's any cost
    session_cost_int=$(python3 -c "import math; print(round($session_cost))" 2>>"$ERROR_LOG")
    session_cost_int=${session_cost_int:-1}
    if [ "$session_cost_int" -eq 0 ] && [ "$session_cost" != "0.00" ]; then
        session_cost_display="1"
    else
        session_cost_display="${session_cost_int}"
    fi
else
    session_cost_display="0"
fi

# Format daily cost (also rounded to nearest, since they should match when it's the only session)
if [ -n "$daily_cost" ] && [ "$daily_cost" != "0.00" ]; then
    # Round to nearest dollar for consistency with session
    daily_cost_int=$(python3 -c "import math; print(round($daily_cost))" 2>>"$ERROR_LOG")
    daily_cost_int=${daily_cost_int:-1}
    if [ "$daily_cost_int" -eq 0 ] && [ "$daily_cost" != "0.00" ]; then
        daily_cost_display="1"
    else
        daily_cost_display="${daily_cost_int}"
    fi
else
    daily_cost_display="0"
fi

# Format the status line with processing time FIRST using sparkles
# ✨12s 🤖Sonnet 4 ⏱️ 1h36m 🪙11k 💰$14 📅$15 🌿xxx 📁xxx
# Using ✨ sparkles for active processing - magic happening!
printf "✨%s 🤖%s ⏱️ %s 🪙%s 💰\$%s 📅\$%s 🌿%s 📁%s" \
    "$processing_time_display" \
    "$model_name" \
    "$session_time" \
    "$tokens_display" \
    "$session_cost_display" \
    "$daily_cost_display" \
    "$git_branch" \
    "$folder_name"
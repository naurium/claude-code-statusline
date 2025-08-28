#!/bin/bash

# Cleanup function to remove lock files and old session files
cleanup() {
    # Clean up lock files
    rm -f /tmp/ccusage_blocks.lock /tmp/ccusage_daily.lock 2>/dev/null
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

# Cache file for ccusage blocks data 
BLOCKS_CACHE="/tmp/ccusage_blocks_cache.json"
DAILY_CACHE="/tmp/ccusage_daily_cache.json"
ERROR_LOG="/tmp/statusline-errors.log"
BLOCKS_CACHE_AGE=120  # 2 minutes for session data
DAILY_CACHE_AGE=300   # 5 minutes for daily totals
BLOCKS_LOCK="/tmp/ccusage_blocks.lock"
DAILY_LOCK="/tmp/ccusage_daily.lock"

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
    # Check if ccusage is available via npx with timeout to prevent hanging
    if command -v gtimeout >/dev/null 2>&1; then
        if gtimeout 2 npx ccusage --help >/dev/null 2>&1; then
            CCUSAGE_AVAILABLE=true
        fi
    elif command -v timeout >/dev/null 2>&1; then
        if timeout 2 npx ccusage --help >/dev/null 2>&1; then
            CCUSAGE_AVAILABLE=true
        fi
    else
        # Skip npx check if no timeout command available (to prevent hanging)
        CCUSAGE_AVAILABLE=false
    fi
fi

# Simple async update function for blocks cache
start_blocks_update() {
    if [ "$CCUSAGE_AVAILABLE" = true ] && [ ! -f "$BLOCKS_LOCK" ]; then
        (
            # Create lock file
            touch "$BLOCKS_LOCK"
            
            # Run update with reasonable timeout
            export NODE_OPTIONS="--max-old-space-size=1024"
            if command -v gtimeout >/dev/null 2>&1; then
                gtimeout 30 ccusage blocks --json > "$BLOCKS_CACHE.tmp" 2>/dev/null
            elif command -v ccusage >/dev/null 2>&1; then
                ccusage blocks --json > "$BLOCKS_CACHE.tmp" 2>/dev/null
            else
                npx ccusage blocks --json > "$BLOCKS_CACHE.tmp" 2>/dev/null
            fi
            
            # If successful and non-empty, replace cache
            if [ -s "$BLOCKS_CACHE.tmp" ]; then
                mv "$BLOCKS_CACHE.tmp" "$BLOCKS_CACHE"
            fi
            
            # Clean up
            rm -f "$BLOCKS_CACHE.tmp" "$BLOCKS_LOCK" 2>/dev/null
        ) &
    fi
}

# Simple async update function for daily cache
start_daily_update() {
    if [ "$CCUSAGE_AVAILABLE" = true ] && [ ! -f "$DAILY_LOCK" ]; then
        (
            # Create lock file
            touch "$DAILY_LOCK"
            
            # Run update with reasonable timeout (daily is slower)
            export NODE_OPTIONS="--max-old-space-size=1024"
            if command -v gtimeout >/dev/null 2>&1; then
                gtimeout 45 ccusage daily --json --since $(date +%Y%m%d) --until $(date +%Y%m%d) > "$DAILY_CACHE.tmp" 2>/dev/null
            elif command -v ccusage >/dev/null 2>&1; then
                ccusage daily --json --since $(date +%Y%m%d) --until $(date +%Y%m%d) > "$DAILY_CACHE.tmp" 2>/dev/null
            else
                npx ccusage daily --json --since $(date +%Y%m%d) --until $(date +%Y%m%d) > "$DAILY_CACHE.tmp" 2>/dev/null
            fi
            
            # If successful and non-empty, replace cache
            if [ -s "$DAILY_CACHE.tmp" ]; then
                mv "$DAILY_CACHE.tmp" "$DAILY_CACHE"
            fi
            
            # Clean up
            rm -f "$DAILY_CACHE.tmp" "$DAILY_LOCK" 2>/dev/null
        ) &
    fi
}

# Clean up orphaned locks (older than 60 seconds)
if [ -f "$BLOCKS_LOCK" ]; then
    lock_age=$(($(date +%s) - $(stat -f %m "$BLOCKS_LOCK" 2>/dev/null || echo 0)))
    if [ "$lock_age" -gt 60 ]; then
        rm -f "$BLOCKS_LOCK"
    fi
fi
if [ -f "$DAILY_LOCK" ]; then
    lock_age=$(($(date +%s) - $(stat -f %m "$DAILY_LOCK" 2>/dev/null || echo 0)))
    if [ "$lock_age" -gt 60 ]; then
        rm -f "$DAILY_LOCK"
    fi
fi

# Check if blocks cache needs update (2 minute interval)
if [ ! -f "$BLOCKS_CACHE" ]; then
    # No cache, create empty one and trigger update
    echo '{"blocks":[]}' > "$BLOCKS_CACHE"
    start_blocks_update
else
    # Check cache age
    cache_age=$(($(date +%s) - $(stat -f %m "$BLOCKS_CACHE" 2>/dev/null || echo 0)))
    if [ "$cache_age" -gt "$BLOCKS_CACHE_AGE" ]; then
        start_blocks_update
    fi
fi

# Check if daily cache needs update (5 minute interval)
if [ ! -f "$DAILY_CACHE" ]; then
    # No cache, create empty one and trigger update
    echo '{"totals":{"totalCost":0,"totalTokens":0}}' > "$DAILY_CACHE"
    start_daily_update
else
    # Check cache age
    cache_age=$(($(date +%s) - $(stat -f %m "$DAILY_CACHE" 2>/dev/null || echo 0)))
    if [ "$cache_age" -gt "$DAILY_CACHE_AGE" ]; then
        start_daily_update
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
    
    # Find active block - but check if it has ended (5-hour limit hit)
    found_active = False
    for block in data.get('blocks', []):
        if block.get('isActive'):
            tokens = block.get('totalTokens', 0)
            cost = block.get('costUSD', 0)
            end_time = block.get('endTime', '')
            
            # Check if block has an endTime
            if end_time:
                # Block has an end time - check if it's in the past or future
                try:
                    if end_time.endswith('Z'):
                        end = datetime.datetime.fromisoformat(end_time.replace('Z', '+00:00'))
                    else:
                        end = datetime.datetime.fromisoformat(end_time)
                    
                    now = datetime.datetime.now(datetime.timezone.utc)
                    
                    if end > now:
                        # End time is in the future - this is a pre-allocated block, still active
                        # Calculate time from start (this is the current session)
                        start_time = block.get('startTime', '')
                        if start_time:
                            if start_time.endswith('Z'):
                                start = datetime.datetime.fromisoformat(start_time.replace('Z', '+00:00'))
                            else:
                                start = datetime.datetime.fromisoformat(start_time)
                            
                            duration = now - start
                            if duration.total_seconds() >= 0:
                                # Don't cap at 5 hours since this is the NEW session after reset
                                hours = int(duration.total_seconds() // 3600)
                                minutes = int((duration.total_seconds() % 3600) // 60)
                            else:
                                hours = 0
                                minutes = 0
                        else:
                            hours = 0
                            minutes = 0
                    else:
                        # End time is in the past - session truly ended
                        hours = 0
                        minutes = 0
                except Exception as e:
                    print(f'End time parsing error: {e}', file=sys.stderr)
                    hours = 0
                    minutes = 0
            else:
                # Calculate session time from start
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
                        
                        # Ensure positive duration and cap at 5 hours
                        if duration.total_seconds() >= 0:
                            total_seconds = min(duration.total_seconds(), 5 * 3600)  # Cap at 5 hours
                            hours = int(total_seconds // 3600)
                            minutes = int((total_seconds % 3600) // 60)
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
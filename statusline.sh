#!/bin/bash

# Cleanup function to remove lock files and old session files
cleanup() {
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

# Cache files
BLOCKS_CACHE="/tmp/ccusage_blocks_cache.json"
DAILY_CACHE="/tmp/ccusage_daily_cache.json"
CACHE_AGE=300  # 5 minutes for both session and daily data (updated together)

# Path to update-cache.sh script
UPDATE_SCRIPT="$HOME/.claude/update-cache.sh"

# Check if cache needs update (both blocks and daily together)
needs_update=false

# Check if either cache file is missing
if [ ! -f "$BLOCKS_CACHE" ] || [ ! -f "$DAILY_CACHE" ]; then
    # Missing cache file(s), need update
    [ ! -f "$BLOCKS_CACHE" ] && echo '{"blocks":[]}' > "$BLOCKS_CACHE"
    [ ! -f "$DAILY_CACHE" ] && echo '{"totals":{"totalCost":0,"totalTokens":0}}' > "$DAILY_CACHE"
    needs_update=true
else
    # Check cache age (both update together, so check blocks cache age)
    cache_age=$(($(date +%s) - $(stat -f %m "$BLOCKS_CACHE" 2>/dev/null || echo 0)))
    if [ "$cache_age" -gt "$CACHE_AGE" ]; then
        needs_update=true
    else
        # Check if the cached date matches today's date (date boundary check)
        cached_date=$(python3 -c "
import json
try:
    with open('$DAILY_CACHE', 'r') as f:
        data = json.load(f)
    # Get the date from the daily data
    daily_entries = data.get('daily', [])
    if daily_entries:
        print(daily_entries[0].get('date', ''))
except:
    pass
" 2>/dev/null)
        
        today_date=$(date +%Y-%m-%d)
        if [ "$cached_date" != "$today_date" ] && [ -n "$cached_date" ]; then
            # Date has changed, force update
            needs_update=true
        fi
    fi
fi

# Trigger update if needed (updates both blocks and daily sequentially)
if [ "$needs_update" = true ]; then
    if [ -x "$UPDATE_SCRIPT" ]; then
        "$UPDATE_SCRIPT" --quiet &  # No flags = update both sequentially
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
                        # Parse ISO format with Z timezone
                        end_dt = datetime.datetime.fromisoformat(end_time.replace('Z', '+00:00'))
                    else:
                        # Parse ISO format
                        end_dt = datetime.datetime.fromisoformat(end_time)
                    
                    # Get current UTC time
                    now_utc = datetime.datetime.now(datetime.timezone.utc)
                    
                    # If end_time is in the future, this is a pre-allocated block
                    # ccusage marks blocks with future endTime when 5-hour limit is hit
                    if end_dt > now_utc:
                        # Block is pre-allocated (5-hour limit hit), don't use its data
                        continue
                except:
                    # If we can't parse the time, assume block is active
                    pass
            
            # Valid active block found
            print(f'{tokens},{cost}')
            found_active = True
            break
    
    if not found_active:
        print('0,0')
        
except Exception as e:
    # On error, output zeros
    print('0,0')
" 2>/dev/null)
    
    # Parse the output
    if [ -n "$block_data" ]; then
        tokens=$(echo "$block_data" | cut -d',' -f1)
        session_cost=$(echo "$block_data" | cut -d',' -f2)
    else
        tokens=0
        session_cost=0
    fi
else
    tokens=0
    session_cost=0
fi

# Parse cached daily data
if [ -f "$DAILY_CACHE" ]; then
    daily_cost=$(python3 -c "
import json
try:
    with open('$DAILY_CACHE', 'r') as f:
        data = json.load(f)
    print(data.get('totals', {}).get('totalCost', 0))
except:
    print(0)
" 2>/dev/null)
else
    daily_cost=0
fi

# Calculate session time
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    # Get session start time from transcript
    session_start=$(python3 -c "
import json, sys
try:
    with open('$transcript_path', 'r') as f:
        data = json.load(f)
    messages = data.get('messages', [])
    if messages:
        # Get the timestamp of the first message
        first_msg = messages[0]
        timestamp = first_msg.get('ts', None)
        if timestamp:
            # Convert ISO timestamp to epoch seconds
            from datetime import datetime
            dt = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
            epoch = int(dt.timestamp())
            print(epoch)
except:
    pass
" 2>/dev/null)
    
    if [ -n "$session_start" ]; then
        current_time=$(date +%s)
        session_elapsed=$((current_time - session_start))
        
        # Check if the active block has ended (5-hour limit)
        # If block has future endTime, session was restarted, so calculate from restart
        if [ -f "$BLOCKS_CACHE" ]; then
            restart_time=$(python3 -c "
import json, datetime

try:
    with open('$BLOCKS_CACHE', 'r') as f:
        data = json.load(f)
    
    # Find active block with future endTime (indicates restart)
    for block in data.get('blocks', []):
        if block.get('isActive'):
            end_time = block.get('endTime', '')
            if end_time:
                try:
                    if end_time.endswith('Z'):
                        end_dt = datetime.datetime.fromisoformat(end_time.replace('Z', '+00:00'))
                    else:
                        end_dt = datetime.datetime.fromisoformat(end_time)
                    
                    now_utc = datetime.datetime.now(datetime.timezone.utc)
                    
                    # If end_time is in the future, session was restarted
                    if end_dt > now_utc:
                        # Calculate when session restarted (5 hours before the future endTime)
                        restart_dt = end_dt - datetime.timedelta(hours=5)
                        print(int(restart_dt.timestamp()))
                        break
                except:
                    pass
except:
    pass
" 2>/dev/null)
            
            if [ -n "$restart_time" ]; then
                # Use restart time instead of original session start
                session_elapsed=$((current_time - restart_time))
            fi
        fi
        
        # Format session time
        if [ "$session_elapsed" -ge 0 ]; then
            hours=$((session_elapsed / 3600))
            minutes=$(((session_elapsed % 3600) / 60))
            
            if [ "$hours" -eq 0 ]; then
                session_time="${minutes}m"
            else
                session_time="${hours}h${minutes}m"
            fi
        else
            session_time="0m"
        fi
    else
        session_time="0m"
    fi
else
    session_time="0m"
fi

# Format tokens (k/M/B)
if [ "$tokens" -ge 1000000000 ]; then
    tokens_display=$((tokens / 1000000000))"B"
elif [ "$tokens" -ge 1000000 ]; then
    tokens_display=$((tokens / 1000000))"M"
elif [ "$tokens" -ge 1000 ]; then
    tokens_display=$((tokens / 1000))"k"
else
    tokens_display="$tokens"
fi

# Format costs (round to nearest dollar)
session_cost_display=$(printf "%.0f" "$session_cost" 2>/dev/null || echo "0")
daily_cost_display=$(printf "%.0f" "$daily_cost" 2>/dev/null || echo "0")

# Get git branch
git_branch=$(cd "$current_dir" 2>/dev/null && git branch --show-current 2>/dev/null | head -c 20)
git_branch=${git_branch:-"no-git"}

# Get directory name (last component of path)
dir_name=$(basename "$current_dir" | head -c 20)

# Build status line
status="✨${processing_time_display} 🤖${model_name} ⏱️${session_time} 🪙${tokens_display} 💰\$${session_cost_display} 📅\$${daily_cost_display} 🌿${git_branch} 📁${dir_name}"

echo "$status"
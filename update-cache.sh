#!/bin/bash

# Script to update cached data (blocks and/or daily)
# Can be run manually or called from statusline.sh

# Parse command line arguments
QUIET=false
BLOCKS_ONLY=false
DAILY_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --quiet)
            QUIET=true
            shift
            ;;
        --blocks-only)
            BLOCKS_ONLY=true
            shift
            ;;
        --daily-only)
            DAILY_ONLY=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Cache files and locks
BLOCKS_CACHE="/tmp/ccusage_blocks_cache.json"
DAILY_CACHE="/tmp/ccusage_daily_cache.json"
UPDATE_LOCK="/tmp/ccusage_update.lock"

# Check if another update is already running
if [ -f "$UPDATE_LOCK" ]; then
    # Check if lock is stale (older than 60 seconds)
    lock_age=$(($(date +%s) - $(stat -f %m "$UPDATE_LOCK" 2>/dev/null || echo 0)))
    if [ "$lock_age" -gt 60 ]; then
        rm -f "$UPDATE_LOCK"
    else
        # Another update is running, exit silently
        exit 0
    fi
fi

# Create lock file with PID for tracking
echo $$ > "$UPDATE_LOCK"

# Cleanup function to ensure lock is removed
cleanup() {
    rm -f "$UPDATE_LOCK" 2>/dev/null
    exit
}
trap cleanup EXIT INT TERM

# Set memory limit to prevent crashes
export NODE_OPTIONS="--max-old-space-size=2048"

# Determine timeout command
if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
else
    TIMEOUT_CMD=""
fi

# Determine ccusage command
if command -v ccusage >/dev/null 2>&1; then
    CMD="ccusage"
else
    CMD="npx ccusage"
fi

# Function to update blocks cache
update_blocks() {
    [ "$QUIET" = false ] && echo "Updating blocks cache..."
    
    if [ -n "$TIMEOUT_CMD" ]; then
        # Use exec to replace shell process and prevent memory leaks
        $TIMEOUT_CMD 30 $CMD blocks --json > "$BLOCKS_CACHE.tmp" 2>/dev/null
    else
        $CMD blocks --json > "$BLOCKS_CACHE.tmp" 2>/dev/null
    fi
    
    if [ -s "$BLOCKS_CACHE.tmp" ]; then
        mv "$BLOCKS_CACHE.tmp" "$BLOCKS_CACHE"
        [ "$QUIET" = false ] && echo "✅ Blocks cache updated"
    else
        [ "$QUIET" = false ] && echo "❌ Failed to update blocks cache"
        rm -f "$BLOCKS_CACHE.tmp"
    fi
}

# Function to update daily cache
update_daily() {
    [ "$QUIET" = false ] && echo "Updating daily cache..."
    
    if [ -n "$TIMEOUT_CMD" ]; then
        # Use exec to replace shell process and prevent memory leaks
        $TIMEOUT_CMD 45 $CMD daily --json --since $(date +%Y%m%d) --until $(date +%Y%m%d) > "$DAILY_CACHE.tmp" 2>/dev/null
    else
        $CMD daily --json --since $(date +%Y%m%d) --until $(date +%Y%m%d) > "$DAILY_CACHE.tmp" 2>/dev/null
    fi
    
    if [ -s "$DAILY_CACHE.tmp" ]; then
        mv "$DAILY_CACHE.tmp" "$DAILY_CACHE"
        [ "$QUIET" = false ] && echo "✅ Daily cache updated"
    else
        [ "$QUIET" = false ] && echo "❌ Failed to update daily cache"
        rm -f "$DAILY_CACHE.tmp"
    fi
}

# Header message
if [ "$QUIET" = false ] && [ "$BLOCKS_ONLY" = false ] && [ "$DAILY_ONLY" = false ]; then
    echo "Updating all cached data..."
fi

# Update based on flags
if [ "$BLOCKS_ONLY" = true ]; then
    update_blocks
elif [ "$DAILY_ONLY" = true ]; then
    update_daily
else
    # Update both
    update_blocks
    update_daily
fi

# Display current stats (only if not quiet and both caches were updated)
if [ "$QUIET" = false ] && [ "$BLOCKS_ONLY" = false ] && [ "$DAILY_ONLY" = false ]; then
    python3 -c "
import json
try:
    with open('$BLOCKS_CACHE', 'r') as f:
        blocks = json.load(f)
    with open('$DAILY_CACHE', 'r') as f:
        daily = json.load(f)
    
    # Find active block
    for block in blocks.get('blocks', []):
        if block.get('isActive'):
            tokens = block.get('totalTokens', 0)
            session_cost = block.get('costUSD', 0)
            break
    else:
        tokens = 0
        session_cost = 0
    
    daily_cost = daily.get('totals', {}).get('totalCost', 0)
    
    # Format tokens
    if tokens >= 1000000:
        tokens_display = f'{tokens//1000000}M'
    elif tokens >= 1000:
        tokens_display = f'{tokens//1000}k'
    else:
        tokens_display = str(tokens)
    
    print(f'')
    print(f'📊 Current stats:')
    print(f'  🪙 Tokens: {tokens_display}')
    print(f'  💰 Session: \${session_cost:.2f}')
    print(f'  📅 Daily: \${daily_cost:.2f}')
except Exception as e:
    print(f'Error reading cache: {e}')
"
fi
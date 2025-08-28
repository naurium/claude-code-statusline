#!/bin/bash

# Manual script to update all cached data (blocks and daily)
# Run this when you want fresh token and cost data immediately

echo "Updating all cached data..."

BLOCKS_CACHE="/tmp/ccusage_blocks_cache.json"
DAILY_CACHE="/tmp/ccusage_daily_cache.json"
BLOCKS_LOCK="/tmp/ccusage_blocks.lock"
DAILY_LOCK="/tmp/ccusage_daily.lock"

# Clean up any existing locks
rm -f "$BLOCKS_LOCK" "$DAILY_LOCK" 2>/dev/null

export NODE_OPTIONS="--max-old-space-size=2048"

# Determine timeout command
if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
else
    TIMEOUT_CMD=""
fi

# Determine ccusage command
if command -v ccusage >/dev/null 2>&1; then
    CMD="ccusage"
else
    CMD="npx ccusage"
fi

# Update blocks cache (30 second timeout)
echo "Updating blocks cache..."
if [ -n "$TIMEOUT_CMD" ]; then
    $TIMEOUT_CMD 30 $CMD blocks --json > "$BLOCKS_CACHE.tmp" 2>/dev/null
else
    $CMD blocks --json > "$BLOCKS_CACHE.tmp" 2>/dev/null
fi

if [ -s "$BLOCKS_CACHE.tmp" ]; then
    mv "$BLOCKS_CACHE.tmp" "$BLOCKS_CACHE"
    echo "✅ Blocks cache updated"
else
    echo "❌ Failed to update blocks cache"
    rm -f "$BLOCKS_CACHE.tmp"
fi

# Update daily cache (45 second timeout)
echo "Updating daily cache..."
if [ -n "$TIMEOUT_CMD" ]; then
    $TIMEOUT_CMD 45 $CMD daily --json --since $(date +%Y%m%d) --until $(date +%Y%m%d) > "$DAILY_CACHE.tmp" 2>/dev/null
else
    $CMD daily --json --since $(date +%Y%m%d) --until $(date +%Y%m%d) > "$DAILY_CACHE.tmp" 2>/dev/null
fi

if [ -s "$DAILY_CACHE.tmp" ]; then
    mv "$DAILY_CACHE.tmp" "$DAILY_CACHE"
    echo "✅ Daily cache updated"
else
    echo "❌ Failed to update daily cache"
    rm -f "$DAILY_CACHE.tmp"
fi

# Extract and display the current stats
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
#!/bin/bash

# Manual script to update all cached data (blocks and daily)
# Run this when you want fresh token and cost data immediately

echo "Updating all cached data..."

export NODE_OPTIONS="--max-old-space-size=4096"  # 4GB for manual updates

# Use longer timeout for manual updates
if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout 60"
elif command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout 60"
else
    TIMEOUT_CMD=""
fi

BLOCKS_CACHE="/tmp/ccusage_blocks_cache.json"
DAILY_CACHE="/tmp/ccusage_daily_cache.json"

if command -v ccusage >/dev/null 2>&1; then
    CMD="ccusage"
else
    CMD="npx ccusage"
fi

# Update blocks cache
echo "Updating blocks cache..."
if $TIMEOUT_CMD $CMD blocks --json > "$BLOCKS_CACHE.tmp" 2>&1; then
    mv "$BLOCKS_CACHE.tmp" "$BLOCKS_CACHE"
    echo "✅ Blocks cache updated"
else
    echo "❌ Failed to update blocks cache"
    rm -f "$BLOCKS_CACHE.tmp"
fi

# Update daily cache
echo "Updating daily cache..."
if $TIMEOUT_CMD $CMD daily --json --since $(date +%Y%m%d) --until $(date +%Y%m%d) > "$DAILY_CACHE.tmp" 2>&1; then
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
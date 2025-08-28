#!/bin/bash

# This hook tracks when user submits a prompt to measure processing time
# It should be called on UserPromptSubmit event

# Clean up old session files (older than 24 hours) at startup
find /tmp -name "claude_processing_start_*.timestamp" -mtime +1 -delete 2>/dev/null

# Read JSON input (limit to prevent memory issues)
input=$(head -c 100000)

# Extract session ID for unique tracking per session
session_id=$(echo "$input" | grep -o '"session_id":"[^"]*"' | sed 's/"session_id":"\([^"]*\)"/\1/' | head -1)
transcript_path=$(echo "$input" | grep -o '"transcript_path":"[^"]*"' | sed 's/"transcript_path":"\([^"]*\)"/\1/' | head -1)

# CRITICAL: Ensure session isolation - each Claude window gets its own timer
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

# Create timestamp file for this specific session only
PROCESSING_TIME_FILE="/tmp/claude_processing_start_${session_id}.timestamp"

# Record current timestamp
date +%s > "$PROCESSING_TIME_FILE"

# Debug logging (optional)
# echo "$(date): UserPromptSubmit captured for session: $session_id" >> /tmp/processing-time-debug.log

# Pass through - hooks should not alter the flow
echo "$input"
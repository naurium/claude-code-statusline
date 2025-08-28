# Claude Code Statusline

Minimal shell scripts for Claude Code CLI status line with real-time processing metrics.

## Status Line Format

```
✨12s 🤖Opus 4.1 ⏱️1h36m 🪙11k 💰$14 📅$15 🌿main 📁project
```

- `✨12s` - Processing time since last message
- `🤖Opus 4.1` - Current AI model
- `⏱️1h36m` - Session duration
- `🪙11k` - Total tokens (k/M/B)
- `💰$14` - Session cost
- `📅$15` - Daily cost
- `🌿main` - Git branch
- `📁project` - Current directory

## Installation

### Automatic Installation via Claude Code

Simply tell Claude: 
```
Install /statusline from https://github.com/naurium/claude-code-statusline
```

### Manual Installation

1. Clone the repository:
```bash
git clone https://github.com/naurium/claude-code-statusline.git
cd claude-code-statusline
```

2. Copy scripts to your Claude directory:
```bash
cp statusline.sh processing-tracker.sh update-cache.sh ~/.claude/
chmod +x ~/.claude/statusline.sh
chmod +x ~/.claude/processing-tracker.sh
chmod +x ~/.claude/update-cache.sh
```

3. Update Claude settings (`~/.claude/settings.json`):
```json
{
  "statusLineCommand": "~/.claude/statusline.sh",
  "hooks": {
    "UserPromptSubmit": ["~/.claude/processing-tracker.sh"]
  }
}
```

4. Restart Claude Code

## Dependencies

### Required
- macOS/Linux
- Python 3

### Optional: ccusage for Cost Tracking

For token usage and cost tracking features to work, install [ccusage](https://github.com/bradleybonitatibus/ccusage):

```bash
npm install -g ccusage
ccusage login
```

Without ccusage, the status line will partially work but show `0` for tokens and costs.

## Performance

Token and cost data is cached for 5 minutes to minimize system load. All Claude instances share the same cache, so only one update runs at a time. To manually refresh all cached data, run:

```bash
bash ~/.claude/update-cache.sh
```

## License

MIT © Naurium Pty Ltd
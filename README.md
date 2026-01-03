# Multi-Agent Compare

Run prompts through 10 AI models in parallel and compare their responses. Built as a [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill.

## Features

- **Parallel execution** with idle timeout (16 min) and hard timeout (40 min)
- **Git reference expansion** - Automatically expands commit SHAs and temporal references ("today", "this week", "last 5 days")
- **Smart file context injection** - Discovers and injects relevant files for code-focused agents
- **Web-enabled agent filtering** (`--web` flag) for real-time information queries
- **Reasoning task filtering** (`--reasoning` flag) to skip code-only models
- **Concurrency control** (`--concurrency N`) to avoid API rate limits
- **Dry run mode** (`--dry-run`) to preview which agents will run
- **Markdown output** with summary tables saved to `./agent-logs/compare/`

## Requirements

### CLI Tools

| Tool | Description | Installation |
|------|-------------|--------------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Anthropic's CLI for Claude | `npm install -g @anthropic-ai/claude-code` |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | Google's Gemini CLI | `npm install -g @anthropic-ai/gemini-cli` |
| [Codex CLI](https://github.com/openai/codex) | OpenAI's Codex CLI | `npm install -g @openai/codex` |
| [Aider](https://aider.chat) | AI pair programming tool | `pip install aider-chat` |
| `jq` | JSON parsing | `sudo dnf install jq` (Fedora) or `brew install jq` (macOS) |

### API Keys

Set these environment variables (e.g., in `~/.bashrc` or `~/.zshrc`):

```bash
export ANTHROPIC_API_KEY="sk-ant-..."      # For Claude
export GOOGLE_AI_API_KEY="..."             # For Gemini
export OPENAI_API_KEY="sk-..."             # For Codex
export OPENROUTER_API_KEY="sk-or-..."      # For Aider models (DeepSeek, Mistral, Grok, Llama)
```

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/multi-agent-compare.git
   cd multi-agent-compare
   ```

2. Copy the agent configuration:
   ```bash
   mkdir -p ~/.claude
   cp agents.json.example ~/.claude/agents.json
   ```

3. Copy the runner script:
   ```bash
   mkdir -p ~/.claude/scripts
   cp run_agents.sh ~/.claude/scripts/
   chmod +x ~/.claude/scripts/run_agents.sh
   ```

4. Copy the Claude Code skill (optional - enables `/compare` command):
   ```bash
   mkdir -p ~/.claude/commands
   cp compare.md ~/.claude/commands/
   ```

5. Set your API keys (see Requirements above)

## Usage

### As a Claude Code Skill

If you installed the skill definition, use the `/compare` command directly:

```
/compare "review this commit for security issues"
```

### Direct Script Usage

Run the script directly with bash:

```bash
# Basic comparison (all 10 agents)
bash ~/.claude/scripts/run_agents.sh "explain the difference between REST and GraphQL"

# Reasoning tasks only (skip code-only models like Qwen3 Coder, Codestral, Grok Code)
bash ~/.claude/scripts/run_agents.sh --reasoning "which is better: microservices or monolith?"

# Web-enabled agents only (Claude, Gemini, Codex)
bash ~/.claude/scripts/run_agents.sh --web "what are the latest Next.js 15 features?"

# Combined flags
bash ~/.claude/scripts/run_agents.sh --web --reasoning "research the best AI agent frameworks in 2025"

# Limit concurrent agents (avoid rate limits)
bash ~/.claude/scripts/run_agents.sh --concurrency 3 "audit this codebase for security issues"

# Dry run (preview which agents will execute)
bash ~/.claude/scripts/run_agents.sh --dry-run "your prompt here"

# Limit git commit expansion
bash ~/.claude/scripts/run_agents.sh --max-commits 5 "review today's commits"
```

### Command-Line Options

| Flag | Description |
|------|-------------|
| `--web` | Only run agents with web access (Claude, Gemini, Codex) |
| `--reasoning` | Skip code-only agents (for opinions, analysis, design discussions) |
| `--concurrency N` | Limit parallel agents to N at a time (default: unlimited) |
| `--max-commits N` | Limit git commit expansion to N commits (default: 10) |
| `--dry-run` | Show what would run without executing |
| `--help` | Show usage information |

## Agent Configuration

The tool comes with 10 pre-configured agents:

| Agent | Type | Context | Web Access | Code-Only |
|-------|------|---------|------------|-----------|
| Claude (Opus) | claude | 200K | ✓ | |
| Gemini (3 Pro) | gemini | 1M | ✓ | |
| Codex (GPT-5.2) | codex | 200K | ✓ | |
| DeepSeek V3 | aider | 131K | | |
| Qwen3 Coder | aider | 262K | | ✓ |
| Mistral Large 3 | aider | 262K | | |
| Grok 4.1 | aider | 500K | | |
| Llama 4 Maverick | aider | 1M | | |
| Codestral | aider | 256K | | ✓ |
| Grok Code | aider | 256K | | ✓ |

### Customizing Agents

Edit `~/.claude/agents.json` to:
- Enable/disable agents (`"enabled": true/false`)
- Change models (`"model": "..."`)
- Add new agents

Agent types supported:
- `claude` - Uses Claude Code CLI
- `gemini` - Uses Gemini CLI
- `codex` - Uses Codex CLI
- `aider` - Uses Aider with OpenRouter models
- `ollama` - Uses local Ollama models (optional)

## Output Format

Results are saved to `./agent-logs/compare/YYYYMMDD-HHMM-prompt-slug.md` with:

- Summary table (agent, status, time, output size)
- Original prompt
- Expanded prompt (if git refs were resolved)
- Each agent's full response

### Example Output

```markdown
# Agent Comparison Results

**Date:** 2025-01-03 14:30:00
**Agents:** 10 (8 succeeded, 2 failed)
**Total Time:** 3m 45s

## Summary

| Agent | Status | Time | Output |
|-------|--------|------|--------|
| Claude (Opus) | ✅ done | 45s | 12KB |
| Gemini (3 Pro) | ✅ done | 38s | 8KB |
| DeepSeek V3 | ✅ done | 1m 12s | 15KB |
...

## Prompt

```
review this code for security issues
```

---

## ✓ Claude (Opus)

**Status:** done | **Time:** 45s

[Full response here]

---
...
```

## Security

- All agents run in **read-only** or **sandboxed** modes
- A safety prefix is injected into all prompts requesting read-only behavior
- Stalled processes are terminated with graceful escalation (SIGTERM → SIGKILL)
- Prompts are written to temp files to avoid shell injection

## Troubleshooting

### Agent not found

If you see "Warning: [tool] CLI not found, skipping [agent]":
- Ensure the CLI tool is installed and in your PATH
- Check with `which claude`, `which gemini`, `which codex`, `which aider`

### Rate limiting

If agents fail due to rate limits:
- Use `--concurrency 2` or `--concurrency 3` to limit parallel requests
- Wait a few minutes between runs

### Context overflow

For very large prompts or many file references:
- The script automatically limits injected file content to 50KB
- Use `--max-commits` to limit git expansion
- Disable some agents in `~/.claude/agents.json`

## License

MIT License - see [LICENSE](LICENSE) file.

## Contributing

Contributions welcome! Please open an issue or PR.

## Credits

Built by [@davidmarsh](https://github.com/davidmarsh) for use with Claude Code.

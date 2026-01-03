---
description: Run a prompt through multiple AI agents and compare results
argument-hint: <prompt>
allowed-tools: Bash(~/.claude/scripts/run_agents.sh), Read
---

# Multi-Agent Comparison

## Prompt
$ARGUMENTS

## Instructions

Run the prompt through enabled agents using the runner script.

### Step 1: Analyze Prompt Requirements

Before running, determine which flags are needed:

#### Web Access (`--web`)

**Needs web access if:**
- Asks about current events, news, or recent announcements
- References specific dates in 2024/2025 or "today/this week"
- Asks for current prices, weather, scores, or live data
- Requests information that changes frequently
- Contains URLs that need to be fetched
- Asks "what is the latest..." or similar recency queries

**Does NOT need web access if:**
- Asks about programming concepts, algorithms, or code
- Requests code review or refactoring
- Asks about established/stable technologies
- General knowledge questions answerable from training data
- Codebase-specific questions (these use file access, not web)

#### Reasoning Tasks (`--reasoning`)

**Skip code-only models if:**
- Asks for opinions, analysis, or comparisons ("What do you think...", "Which is better...")
- Design discussions or architectural decisions
- General knowledge or explanatory questions
- Writing or prose generation
- Questions about best practices or tradeoffs
- Subjective or open-ended questions

**Include code-only models if:**
- Code review, refactoring, or implementation
- Bug fixes or debugging
- File/codebase exploration
- Code generation or completion
- Technical implementation questions

### Step 2: Execute

Based on your analysis, combine flags as needed:

**Code task (all agents):**
```bash
bash ~/.claude/scripts/run_agents.sh "<prompt>"
```

**Reasoning/opinion task (skip code-only models):**
```bash
bash ~/.claude/scripts/run_agents.sh --reasoning "<prompt>"
```

**Web-required task (only web-enabled agents):**
```bash
bash ~/.claude/scripts/run_agents.sh --web "<prompt>"
```

**Web + reasoning (web-enabled, general-purpose only):**
```bash
bash ~/.claude/scripts/run_agents.sh --web --reasoning "<prompt>"
```

### How It Works

The script:
- Reads enabled agents from `~/.claude/agents.json`
- Writes prompt to temp file (avoids shell injection)
- Runs agents in parallel with **idle timeout** (16 min no output = stalled)
- Cleans up temp files on exit
- Saves logs to `./agent-logs/compare/` in current directory
- Exits non-zero if any agent fails

### Analyze Results

After collecting responses, provide a summary that starts with:

**Prompt:** `<the original prompt>`

Then include:
1. **Summary table** - Key points from each agent (2-3 bullets each)
2. **Agreement analysis** - Where agents agree/disagree
3. **Unique insights** - Points only one agent raised
4. **Recommendation** - Which response(s) best address the prompt

### Exit Codes
- `0` = All agents succeeded
- `1` = One or more agents failed/stalled
- `124` = Agent stalled (no output for idle timeout)
- `125` = Agent hit hard timeout (40 min)

### Agent Capabilities

**Web access (use `--web` to filter):**
- Claude - WebSearch + WebFetch tools (default)
- Gemini - Built-in google_web_search (sandboxed, no shell)
- Codex - Built-in web_search tool (read-only sandbox)
- Aider agents - No web search (code-focused)

**Code-only models (skipped with `--reasoning`):**
- Qwen3 Coder, Codestral, Grok Code

**General-purpose models (included with `--reasoning`):**
- Claude, Gemini, Codex, DeepSeek V3, Mistral Large 3, Grok 4.1, Llama 4 Maverick

Security notes:
- All agents run with **read-only** or **sandboxed** modes to prevent file modifications
- A safety prefix is injected into all prompts requesting read-only behavior
- Stalled processes are terminated with graceful escalation (SIGTERM -> child cleanup -> SIGKILL)

### Requirements
- `jq` must be installed for JSON parsing
- Agent CLIs must be in PATH (claude, gemini, codex, aider)
- API keys configured for each provider

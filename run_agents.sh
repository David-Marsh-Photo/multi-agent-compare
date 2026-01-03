#!/usr/bin/env bash
# Multi-agent comparison runner with idle timeout
# Usage: run_agents.sh [--web] [--reasoning] "prompt here"
#
# Reads agent config from .claude/agents.json
# Uses idle timeout (no output) instead of hard timeout
#
# Options:
#   --web        Only run agents with web_access=true (for prompts needing real-time info)
#   --reasoning  Skip code-only agents (for reasoning/opinion tasks)
#   (default: run all enabled agents)

set -o pipefail

IDLE_TIMEOUT=960  # Kill if no output for 960 seconds (16 min - allows for slow reasoning models)
HARD_TIMEOUT=2400  # Absolute max runtime per agent (40 minutes) - prevents infinite hangs
CHECK_INTERVAL=5  # Check every 5 seconds
WEB_ONLY=false    # When true, only run web-enabled agents
REASONING_ONLY=false  # When true, skip code-only agents (for reasoning/opinion tasks)
MAX_COMMITS=10    # Limit git expansion to prevent context overflow (0=unlimited)
MAX_CONCURRENCY=0 # Max parallel agents (0=unlimited, N=limit to N at a time)
DRY_RUN=false     # When true, show what would run without executing
FILE_INJECT_MAX_BYTES=50000  # Max bytes to inject into prompt for Aider (prevents context overflow)

# ═══════════════════════════════════════════════════════════════════════════════
# ASCII Visualization - Colors and Symbols
# ═══════════════════════════════════════════════════════════════════════════════

# ANSI color codes
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_CYAN='\033[36m'
C_WHITE='\033[37m'

# Status symbols
SYM_CHECK='✓'
SYM_CROSS='✗'
SYM_STAR='★'

# Terminal dimensions
TERM_COLS=$(tput cols 2>/dev/null || echo 80)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENTS_CONFIG="$REPO_ROOT/.claude/agents.json"

# ═══════════════════════════════════════════════════════════════════════════════
# Argument Parsing
# ═══════════════════════════════════════════════════════════════════════════════

# Parse flags
while [[ "$1" == --* ]]; do
    case "$1" in
        --web)
            WEB_ONLY=true
            shift
            ;;
        --reasoning)
            REASONING_ONLY=true
            shift
            ;;
        --max-commits)
            MAX_COMMITS="$2"
            shift 2
            ;;
        --max-commits=*)
            MAX_COMMITS="${1#*=}"
            shift
            ;;
        --concurrency)
            MAX_CONCURRENCY="$2"
            shift 2
            ;;
        --concurrency=*)
            MAX_CONCURRENCY="${1#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            echo "Usage: run_agents.sh [OPTIONS] \"prompt here\""
            echo ""
            echo "Options:"
            echo "  --web              Only run agents with web_access=true"
            echo "                     (for prompts requiring real-time information)"
            echo "  --reasoning        Skip code-only agents (for reasoning/opinion tasks)"
            echo "                     (agents with code_only=true will be skipped)"
            echo "  --max-commits N    Limit git expansion to N commits (default: 10)"
            echo "                     Use 0 for unlimited (may cause context overflow)"
            echo "  --concurrency N    Limit parallel agents (default: 0 = unlimited)"
            echo "                     Useful to avoid API rate limits"
            echo "  --dry-run          Show what would run without executing"
            echo ""
            echo "By default, all enabled agents are run in parallel."
            echo "Flags can be combined: --web --reasoning --concurrency 3"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Validate numeric arguments
if [[ ! "$MAX_COMMITS" =~ ^[0-9]+$ ]]; then
    echo "Error: --max-commits must be a non-negative integer (got: '$MAX_COMMITS')" >&2
    exit 1
fi
if [[ ! "$MAX_CONCURRENCY" =~ ^[0-9]+$ ]]; then
    echo "Error: --concurrency must be a non-negative integer (got: '$MAX_CONCURRENCY')" >&2
    exit 1
fi

# Validate input
if [[ -z "$1" ]]; then
    echo "Usage: run_agents.sh [--web] \"prompt here\"" >&2
    exit 1
fi

# Check for required commands
for cmd in jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' not found" >&2
        exit 1
    fi
done

# Check agents config exists
if [[ ! -f "$AGENTS_CONFIG" ]]; then
    echo "Error: Agents config not found: $AGENTS_CONFIG" >&2
    exit 1
fi

# Create unique temp directory for this run
WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'agent_compare')
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

# Expand git refs in the prompt (commits, branches, etc.)
# This ensures all agents can see commit contents even if they can't run git commands
expand_git_refs() {
    local text="$1"
    local expanded="$text"
    local git_context=""

    # Find potential git SHAs (7-40 hex chars that are valid refs)
    # Also match common patterns like HEAD~1, branch names after "commit", etc.
    local refs_found=()

    # Extract potential SHA patterns (word boundaries, 7-40 hex chars)
    while IFS= read -r potential_ref; do
        [[ -z "$potential_ref" ]] && continue
        # Verify it's a valid git ref
        if git rev-parse --verify "$potential_ref^{commit}" &>/dev/null 2>&1; then
            # Check if we haven't already processed this ref
            local already_found=false
            for existing in "${refs_found[@]}"; do
                if [[ "$existing" == "$potential_ref" ]]; then
                    already_found=true
                    break
                fi
            done
            if [[ "$already_found" == "false" ]]; then
                refs_found+=("$potential_ref")
            fi
        fi
    done < <(echo "$text" | grep -oE '\b[a-f0-9]{7,40}\b' 2>/dev/null)

    # Also check for explicit patterns like "commit abc123" or "review abc123"
    while IFS= read -r potential_ref; do
        [[ -z "$potential_ref" ]] && continue
        if git rev-parse --verify "$potential_ref^{commit}" &>/dev/null 2>&1; then
            local already_found=false
            for existing in "${refs_found[@]}"; do
                if [[ "$existing" == "$potential_ref" ]]; then
                    already_found=true
                    break
                fi
            done
            if [[ "$already_found" == "false" ]]; then
                refs_found+=("$potential_ref")
            fi
        fi
    done < <(echo "$text" | grep -oiE '(commit|review|diff|show|cherry-pick)\s+([a-f0-9]{7,40}|HEAD~?[0-9]*|[a-zA-Z][-a-zA-Z0-9_/]*)' 2>/dev/null | awk '{print $2}')

    # Detect temporal references (today, yesterday, this week, recent, last N days)
    local temporal_commits=()
    local text_lower
    text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    # Build git log args with optional --max-count
    local max_count_arg=""
    if [[ "$MAX_COMMITS" -gt 0 ]]; then
        max_count_arg="--max-count=$MAX_COMMITS"
    fi

    if [[ "$text_lower" =~ today|today\'s ]]; then
        # Get commits from today (since midnight)
        while IFS= read -r commit_sha; do
            [[ -n "$commit_sha" ]] && temporal_commits+=("$commit_sha")
        done < <(git log --since="midnight" $max_count_arg --format="%H" 2>/dev/null)
    elif [[ "$text_lower" =~ yesterday|yesterday\'s ]]; then
        # Get commits from yesterday
        while IFS= read -r commit_sha; do
            [[ -n "$commit_sha" ]] && temporal_commits+=("$commit_sha")
        done < <(git log --since="yesterday midnight" --until="today midnight" $max_count_arg --format="%H" 2>/dev/null)
    elif [[ "$text_lower" =~ this\ week|this\ week\'s ]]; then
        # Get commits from this week
        while IFS= read -r commit_sha; do
            [[ -n "$commit_sha" ]] && temporal_commits+=("$commit_sha")
        done < <(git log --since="1 week ago" $max_count_arg --format="%H" 2>/dev/null)
    elif [[ "$text_lower" =~ last\ ([0-9]+)\ day ]]; then
        # Get commits from last N days
        local days="${BASH_REMATCH[1]}"
        while IFS= read -r commit_sha; do
            [[ -n "$commit_sha" ]] && temporal_commits+=("$commit_sha")
        done < <(git log --since="$days days ago" $max_count_arg --format="%H" 2>/dev/null)
    elif [[ "$text_lower" =~ recent\ commit|latest\ commit ]]; then
        # Get last 10 commits (or max_count if lower)
        local recent_limit=10
        [[ "$MAX_COMMITS" -gt 0 && "$MAX_COMMITS" -lt 10 ]] && recent_limit="$MAX_COMMITS"
        while IFS= read -r commit_sha; do
            [[ -n "$commit_sha" ]] && temporal_commits+=("$commit_sha")
        done < <(git log -"$recent_limit" --format="%H" 2>/dev/null)
    fi

    # Add temporal commits to refs_found (avoiding duplicates)
    for commit_sha in "${temporal_commits[@]}"; do
        local already_found=false
        for existing in "${refs_found[@]}"; do
            if [[ "$existing" == "$commit_sha" ]]; then
                already_found=true
                break
            fi
        done
        if [[ "$already_found" == "false" ]]; then
            refs_found+=("$commit_sha")
        fi
    done

    # Expand each found ref (use compact format to prevent aider from auto-detecting file paths)
    for ref in "${refs_found[@]}"; do
        local commit_info
        # Use --shortstat instead of --stat to avoid listing individual files
        # This prevents aider from auto-adding all modified files to context
        commit_info=$(git show "$ref" --shortstat --format="commit %H%nAuthor: %an <%ae>%nDate: %ad%n%n%s%n%n%b" 2>/dev/null)
        if [[ -n "$commit_info" ]]; then
            git_context+="
--- Git Commit: $ref ---
$commit_info
--- End Commit ---
"
        fi
    done

    # If we found git context, append it to the prompt
    if [[ -n "$git_context" ]]; then
        echo "$expanded"
        echo ""
        echo "=== Expanded Git References ==="
        echo "$git_context"
    else
        echo "$expanded"
    fi
}

# Write prompt to file to avoid shell escaping issues
PROMPT_FILE="$WORK_DIR/prompt.txt"
cat > "$PROMPT_FILE" << 'SAFETY_PREFIX'
[IMPORTANT: This is a READ-ONLY query. Do NOT modify any files, run destructive commands, or make git commits. Only provide analysis/answers.]

SAFETY_PREFIX

# Expand git refs and append to prompt
expanded_prompt=$(expand_git_refs "$1")
echo "$expanded_prompt" >> "$PROMPT_FILE"

# Show if git refs were expanded
if [[ "$expanded_prompt" == *"=== Expanded Git References ==="* ]]; then
    # Count how many commits were expanded
    commit_count=$(echo "$expanded_prompt" | grep -c "^--- Git Commit:" || echo 0)
    if [[ "$MAX_COMMITS" -gt 0 && "$commit_count" -ge "$MAX_COMMITS" ]]; then
        echo "Git references detected and expanded in prompt (limited to $MAX_COMMITS commits)"
    else
        echo "Git references detected and expanded in prompt ($commit_count commits)"
    fi
fi

# Get file size portably (works on GNU and BSD/macOS)
get_file_size() {
    wc -c < "$1" 2>/dev/null | tr -d ' '
}

# Format elapsed time nicely (Xm XXs for 60+ seconds, Xs for under)
format_elapsed() {
    local elapsed="$1"
    # Remove decimals for display
    local secs="${elapsed%.*}"
    if [[ $secs -ge 60 ]]; then
        local mins=$((secs / 60))
        local remaining_secs=$((secs % 60))
        printf '%dm %02ds' "$mins" "$remaining_secs"
    else
        printf '%ds' "$secs"
    fi
}

# Slugify text for filename (lowercase, replace spaces/special chars with dashes)
slugify() {
    echo "$1" | \
        tr '\n\r' '  ' | \
        tr '[:upper:]' '[:lower:]' | \
        sed 's/[^a-z0-9]/-/g' | \
        sed 's/--*/-/g' | \
        sed 's/^-//' | \
        sed 's/-$//' | \
        cut -c1-60
}

# Extract file paths from prompt text
# Returns space-separated list of existing files mentioned in the prompt
# FIX 2: Also includes git untracked/new files (not just files on disk)
extract_files_from_prompt() {
    local text="$1"
    local found_files=()

    # Build list of all known files (tracked + untracked in git)
    # This allows discovering files mentioned in prompt that are newly created
    local all_known_files
    all_known_files=$(git ls-files 2>/dev/null)
    # Also add untracked files (new files not yet committed)
    all_known_files+=$'\n'
    all_known_files+=$(git status --porcelain 2>/dev/null | grep -E '^\?\?|^A ' | sed 's/^.. //')

    # Helper: check if file exists on disk OR in git tracked/untracked list
    file_is_known() {
        local file="$1"
        [[ -f "$file" ]] && return 0
        echo "$all_known_files" | grep -qFx "$file" && return 0
        return 1
    }

    # Pattern 1: Explicit paths with extensions (e.g., docs/plans/email-automation.md)
    # Matches paths with common code file extensions
    while IFS= read -r potential_file; do
        [[ -z "$potential_file" ]] && continue
        # Clean up the path (remove surrounding quotes, backticks, etc.)
        potential_file=$(echo "$potential_file" | sed "s/^['\"\`]//;s/['\"\`]$//")
        # Check if file exists or is known to git
        if file_is_known "$potential_file"; then
            # Check if already in list
            local already_found=false
            for existing in "${found_files[@]}"; do
                if [[ "$existing" == "$potential_file" ]]; then
                    already_found=true
                    break
                fi
            done
            if [[ "$already_found" == "false" ]]; then
                found_files+=("$potential_file")
            fi
        fi
    done < <(echo "$text" | grep -oE '[a-zA-Z0-9_./-]+\.(md|ts|tsx|js|jsx|py|sql|json|yaml|yml|sh|css|scss|html|go|rs|java|c|cpp|h|hpp|rb|php)' 2>/dev/null)

    # Pattern 2: src/ or docs/ paths that might not have been caught
    while IFS= read -r potential_file; do
        [[ -z "$potential_file" ]] && continue
        potential_file=$(echo "$potential_file" | sed "s/^['\"\`]//;s/['\"\`]$//")
        if file_is_known "$potential_file"; then
            local already_found=false
            for existing in "${found_files[@]}"; do
                if [[ "$existing" == "$potential_file" ]]; then
                    already_found=true
                    break
                fi
            done
            if [[ "$already_found" == "false" ]]; then
                found_files+=("$potential_file")
            fi
        fi
    done < <(echo "$text" | grep -oE '(src|docs|lib|test|tests|scripts|supabase)/[a-zA-Z0-9_./-]+' 2>/dev/null)

    # Output space-separated list
    echo "${found_files[*]}"
}

# Inject file contents directly into prompt text
# This ensures models that can't use Aider's file access still see the content
# FIX 5: Solves "I don't have access to files" issue with DeepSeek, Grok, Llama
inject_file_contents() {
    local prompt="$1"
    local files="$2"
    local max_bytes="${FILE_INJECT_MAX_BYTES:-50000}"
    local injected=""
    local total_bytes=0
    local injected_count=0
    local skipped_count=0

    for file in $files; do
        [[ -z "$file" || ! -f "$file" ]] && continue

        local file_size
        file_size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')

        # Skip if adding this file would exceed limit
        if [[ $((total_bytes + file_size)) -gt $max_bytes ]]; then
            injected+="
--- FILE: $file (SKIPPED - would exceed ${max_bytes} byte limit) ---"
            skipped_count=$((skipped_count + 1))
            continue
        fi

        injected+="
--- FILE: $file ---
$(cat "$file" 2>/dev/null)
--- END FILE ---"
        total_bytes=$((total_bytes + file_size))
        injected_count=$((injected_count + 1))
    done

    if [[ -n "$injected" ]]; then
        echo "$prompt

=== FILE CONTENTS (${injected_count} files, ${total_bytes} bytes) ===$injected"
    else
        echo "$prompt"
    fi
}

# Discover files based on keywords in prompt
# Returns space-separated list of relevant files for the query type
discover_files_by_keywords() {
    local text="$1"
    local text_lower
    text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    local discovered=()
    local subtree=""

    # API routes / endpoints
    # FIX 1: Extract specific API paths from prompt before falling back to generic discovery
    if [[ "$text_lower" =~ api|route|endpoint|handler ]]; then
        # First, try to extract specific API subdirectories mentioned in prompt
        # e.g., "api/admin/newsletter/campaigns" from file paths in prompt
        local api_subpaths
        api_subpaths=$(echo "$text" | grep -oE 'api/[a-zA-Z0-9/_\[\]-]+' | sort -u | head -10)

        if [[ -n "$api_subpaths" ]]; then
            # Prioritize mentioned API paths
            while IFS= read -r subpath; do
                [[ -z "$subpath" ]] && continue
                # Find route files within the mentioned subdirectory
                while IFS= read -r f; do
                    [[ -n "$f" ]] && discovered+=("$f")
                done < <(find "src/app/$subpath" -name 'route.ts' -type f 2>/dev/null | head -10)
            done <<< "$api_subpaths"
            subtree="src/app/api"
        else
            # Fallback: generic API route discovery (alphabetical, may miss some)
            while IFS= read -r f; do
                [[ -n "$f" ]] && discovered+=("$f")
            done < <(find src/app/api -name 'route.ts' -type f 2>/dev/null | head -40)
            subtree="src/app/api"
        fi
    fi

    # FIX 3: Newsletter-specific discovery
    if [[ "$text_lower" =~ newsletter|campaign|email.*(send|broadcast) ]]; then
        # Newsletter API routes
        while IFS= read -r f; do
            [[ -n "$f" ]] && discovered+=("$f")
        done < <(find src/app/api -path '*newsletter*' -name 'route.ts' -type f 2>/dev/null | head -20)
        # Newsletter services
        while IFS= read -r f; do
            [[ -n "$f" ]] && discovered+=("$f")
        done < <(find src/services -name '*newsletter*' -type f 2>/dev/null | head -10)
        # Newsletter components
        while IFS= read -r f; do
            [[ -n "$f" ]] && discovered+=("$f")
        done < <(find src/components -path '*newsletter*' -name '*.tsx' -type f 2>/dev/null | head -15)
    fi

    # Validators / Zod schemas
    if [[ "$text_lower" =~ zod|validat|schema|safeParse|parse ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && discovered+=("$f")
        done < <(find src/lib/validators -name '*.ts' -type f 2>/dev/null | head -20)
    fi

    # Services
    if [[ "$text_lower" =~ service ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && discovered+=("$f")
        done < <(find src/services -name '*.ts' -type f 2>/dev/null | head -25)
    fi

    # Components
    if [[ "$text_lower" =~ component|ui|form|button ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && discovered+=("$f")
        done < <(find src/components -name '*.tsx' -type f 2>/dev/null | head -30)
    fi

    # Auth / security
    if [[ "$text_lower" =~ auth|security|permission|role|rls ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && discovered+=("$f")
        done < <(find src -name '*auth*' -o -name '*permission*' -type f 2>/dev/null | grep -E '\.(ts|tsx)$' | head -15)
        # Add RLS policies if asking about security
        while IFS= read -r f; do
            [[ -n "$f" ]] && discovered+=("$f")
        done < <(find supabase/migrations -name '*.sql' -type f 2>/dev/null | grep -iE 'rls|policy|security' | head -10)
    fi

    # Database / migrations
    if [[ "$text_lower" =~ migration|database|schema|table|supabase ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && discovered+=("$f")
        done < <(find supabase/migrations -name '*.sql' -type f 2>/dev/null | tail -20)
    fi

    # Error handling
    if [[ "$text_lower" =~ error|exception|catch|throw ]]; then
        [[ -f "src/lib/errors.ts" ]] && discovered+=("src/lib/errors.ts")
        [[ -f "src/lib/logger.ts" ]] && discovered+=("src/lib/logger.ts")
    fi

    # Rate limiting
    if [[ "$text_lower" =~ rate.?limit|throttl ]]; then
        [[ -f "src/lib/rateLimit.ts" ]] && discovered+=("src/lib/rateLimit.ts")
    fi

    # Output format: "subtree:file1 file2 file3" or just "file1 file2 file3"
    if [[ -n "$subtree" ]]; then
        echo "SUBTREE:$subtree ${discovered[*]}"
    else
        echo "${discovered[*]}"
    fi
}

# Results directory for comparison logs (override with COMPARE_LOG_DIR for global use)
RESULTS_DIR="${COMPARE_LOG_DIR:-$REPO_ROOT/agent-logs/compare}"
mkdir -p "$RESULTS_DIR"

# Run a single agent with idle timeout and hard timeout monitoring
# Returns: 0=success, 124=idle timeout, 125=hard timeout, other=agent error
run_agent() {
    local name="$1"
    local outfile="$2"
    shift 2
    local cmd=("$@")

    # Start agent in its own process group for clean killing of entire tree
    setsid "${cmd[@]}" > "$outfile" 2>&1 &
    local pid=$!
    local pgid=$pid  # setsid makes PID = PGID

    local last_size=0
    local idle_seconds=0
    local start_time=$(date +%s)

    while kill -0 "$pid" 2>/dev/null; do
        sleep "$CHECK_INTERVAL"
        local total_seconds=$(($(date +%s) - start_time))

        # Hard timeout check (absolute wall-clock limit)
        if [[ $total_seconds -ge $HARD_TIMEOUT ]]; then
            echo "[$name] Hard timeout (${HARD_TIMEOUT}s), terminating..." >&2
            # Kill entire process group
            kill -TERM -"$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
            sleep 2
            kill -9 -"$pgid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 125  # Hard timeout exit code
        fi

        # Idle timeout check (no output)
        local current_size
        current_size=$(get_file_size "$outfile")

        if [[ "$current_size" == "$last_size" ]]; then
            idle_seconds=$((idle_seconds + CHECK_INTERVAL))
            if [[ $idle_seconds -ge $IDLE_TIMEOUT ]]; then
                echo "[$name] Idle timeout (${IDLE_TIMEOUT}s no output), terminating..." >&2
                # Kill entire process group
                kill -TERM -"$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
                sleep 2
                kill -9 -"$pgid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
                wait "$pid" 2>/dev/null
                return 124  # Idle timeout exit code
            fi
        else
            idle_seconds=0
            last_size="$current_size"
        fi
    done

    wait "$pid"
    return $?
}

# Read enabled agents from config
declare -a AGENT_NAMES
declare -a AGENT_PIDS
declare -a AGENT_OUTFILES
declare -a AGENT_STATUSES
declare -a AGENT_START_TIMES
declare -a AGENT_ELAPSED
declare -a AGENT_TYPES

# Parse agents.json and launch enabled agents
agent_count=$(jq '.agents | length' "$AGENTS_CONFIG")
prompt_content=$(cat "$PROMPT_FILE")

# Handle dry-run mode
if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN - Would run the following agents:"
    echo ""
    dry_run_count=0
    for ((i=0; i<agent_count; i++)); do
        enabled=$(jq -r ".agents[$i].enabled" "$AGENTS_CONFIG")
        [[ "$enabled" != "true" ]] && continue

        name=$(jq -r ".agents[$i].name" "$AGENTS_CONFIG")
        type=$(jq -r ".agents[$i].type" "$AGENTS_CONFIG")
        model=$(jq -r ".agents[$i].model" "$AGENTS_CONFIG")
        web_access=$(jq -r ".agents[$i].web_access // false" "$AGENTS_CONFIG")
        code_only=$(jq -r ".agents[$i].code_only // false" "$AGENTS_CONFIG")

        # Apply same filtering as actual run
        if [[ "$WEB_ONLY" == "true" && "$web_access" != "true" ]]; then
            continue
        fi
        if [[ "$REASONING_ONLY" == "true" && "$code_only" == "true" ]]; then
            continue
        fi

        echo "  - $name ($type: $model)"
        dry_run_count=$((dry_run_count + 1))
    done
    echo ""
    echo "Total: $dry_run_count agents"
    echo "Prompt: $1"
    echo ""
    echo "Flags: web_only=$WEB_ONLY, reasoning_only=$REASONING_ONLY, max_commits=$MAX_COMMITS, concurrency=$MAX_CONCURRENCY"
    exit 0
fi

# Track skipped agents for display
SKIPPED_AGENTS=()
if [[ "$WEB_ONLY" == "true" && "$REASONING_ONLY" == "true" ]]; then
    printf "${C_CYAN}🌐🧠 Running web-enabled, general-purpose agents only${C_RESET}\n"
elif [[ "$WEB_ONLY" == "true" ]]; then
    printf "${C_CYAN}🌐 Running web-enabled agents only${C_RESET}\n"
elif [[ "$REASONING_ONLY" == "true" ]]; then
    printf "${C_CYAN}🧠 Running general-purpose agents only (skipping code-only)${C_RESET}\n"
fi

# Track which agents need post-processing (e.g., Gemini noise filtering)
declare -a GEMINI_RAW_FILES

for ((i=0; i<agent_count; i++)); do
    enabled=$(jq -r ".agents[$i].enabled" "$AGENTS_CONFIG")
    if [[ "$enabled" != "true" ]]; then
        continue
    fi

    name=$(jq -r ".agents[$i].name" "$AGENTS_CONFIG")
    type=$(jq -r ".agents[$i].type" "$AGENTS_CONFIG")
    model=$(jq -r ".agents[$i].model" "$AGENTS_CONFIG")
    web_access=$(jq -r ".agents[$i].web_access // false" "$AGENTS_CONFIG")

    # Skip non-web agents if --web flag was passed
    if [[ "$WEB_ONLY" == "true" && "$web_access" != "true" ]]; then
        SKIPPED_AGENTS+=("$name")
        continue
    fi

    # Skip code-only agents if --reasoning flag was passed
    code_only=$(jq -r ".agents[$i].code_only // false" "$AGENTS_CONFIG")
    if [[ "$REASONING_ONLY" == "true" && "$code_only" == "true" ]]; then
        SKIPPED_AGENTS+=("$name")
        continue
    fi

    # Validate required fields
    if [[ -z "$type" || "$type" == "null" ]]; then
        echo "Warning: Agent '$name' has no type field, skipping" >&2
        continue
    fi

    # Check CLI/dependency exists for this agent type
    case "$type" in
        claude)
            if ! command -v claude &>/dev/null; then
                echo "Warning: claude CLI not found, skipping $name" >&2
                continue
            fi
            ;;
        gemini)
            if ! command -v gemini &>/dev/null; then
                echo "Warning: gemini CLI not found, skipping $name" >&2
                continue
            fi
            ;;
        codex)
            if ! command -v codex &>/dev/null; then
                echo "Warning: codex CLI not found, skipping $name" >&2
                continue
            fi
            ;;
        aider)
            if ! command -v aider &>/dev/null; then
                echo "Warning: aider CLI not found, skipping $name" >&2
                continue
            fi
            ;;
        ollama)
            if ! curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
                echo "Warning: Ollama not responding, skipping $name" >&2
                continue
            fi
            ;;
    esac

    outfile="$WORK_DIR/agent_${i}.txt"
    AGENT_NAMES+=("$name")
    AGENT_OUTFILES+=("$outfile")
    AGENT_START_TIMES+=("$(date +%s)")

    # Launch based on agent type (using type field for robust dispatch)
    # Web access notes:
    #   - claude: WebSearch + WebFetch tools included by default
    #   - gemini: Built-in google_web_search tool (auto-invokes when needed)
    #   - codex: --search flag enables web_search tool
    #   - aider: No native web search (Playwright for scraping only, not search)
    #   - ollama: Local models, no web access
    case "$type" in
        claude)
            # Web access: WebSearch + WebFetch tools available by default
            run_agent "$name" "$outfile" claude -p "$prompt_content" --model "$model" --output-format text &
            ;;
        gemini)
            # Web access: Built-in google_web_search tool auto-invokes when needed
            # --yolo: auto-approve tool calls (needed for non-interactive)
            # Default sandbox=true blocks shell commands for safety
            raw_outfile="$WORK_DIR/gemini_raw_${i}.txt"
            GEMINI_RAW_FILES+=("$raw_outfile:$outfile")
            run_agent "$name" "$raw_outfile" gemini "$prompt_content" -m "$model" -o text --yolo &
            ;;
        codex)
            # Web access: Codex has built-in web_search tool (no flag needed)
            # -s read-only: sandbox allows reading but prevents file modifications
            # --skip-git-repo-check: allows running outside git repos (e.g., home directory)
            run_agent "$name" "$outfile" codex exec "$prompt_content" -m "$model" -s read-only --skip-git-repo-check &
            ;;
        aider)
            # Web access: None (Playwright scraping only, no search capability)
            # --dry-run: don't modify files, --no-auto-commits: don't commit
            # --map-tokens 8192: increased for better repo structure awareness
            # --file: files aider can analyze (even in dry-run, gives full context)
            # --read: read-only context files (guardrails, core docs)
            # --subtree-only: focus on relevant directory when detected
            # Allows git read access (git log, etc.) while preventing writes
            #
            # Step 1: Discover files based on prompt keywords (API routes, validators, etc.)
            keyword_discovery=$(discover_files_by_keywords "$prompt_content")
            aider_subtree=""
            discovered_files=""

            # Parse subtree hint if present (format: "SUBTREE:path file1 file2...")
            if [[ "$keyword_discovery" == SUBTREE:* ]]; then
                # Extract subtree path (first word after SUBTREE:)
                aider_subtree=$(echo "$keyword_discovery" | sed 's/^SUBTREE:\([^ ]*\).*/\1/')
                # Extract files (everything after the subtree path)
                discovered_files=$(echo "$keyword_discovery" | sed 's/^SUBTREE:[^ ]* //')
            else
                discovered_files="$keyword_discovery"
            fi

            # Step 2: Extract explicitly mentioned files from prompt
            extracted_files=$(extract_files_from_prompt "$prompt_content")

            # Combine discovered + extracted files (deduped)
            all_files="$discovered_files $extracted_files"

            aider_file_args=()
            aider_extra_args=()
            file_count=0
            # Limit files to avoid context overflow on smaller models
            # DeepSeek reserves ~65K for output, so input must be <100K
            # 15 files + context docs + 2K repo-map ≈ 60-80K tokens
            max_files=15

            # Note: --subtree-only cannot be used with --file arguments
            # We'll use subtree-only ONLY if no files were discovered (fallback mode)
            # Otherwise, explicit files give better context than subtree-only

            # Add discovered/extracted files
            for ef in $all_files; do
                [[ -z "$ef" ]] && continue
                # Skip binary files (PDFs, images, etc.)
                case "$ef" in
                    *.pdf|*.png|*.jpg|*.jpeg|*.gif|*.pptx|*.docx|*.xlsx)
                        continue
                        ;;
                esac
                # Skip if file doesn't exist
                [[ ! -f "$ef" ]] && continue
                # Avoid duplicates
                if [[ " ${aider_file_args[*]} " =~ " --file $ef " ]]; then
                    continue
                fi
                # Limit file count
                if [[ $file_count -ge $max_files ]]; then
                    echo "[$name] Limiting to $max_files files to prevent context overflow" >&2
                    break
                fi
                # Use --file for full context (works with dry-run)
                aider_file_args+=(--file "$ef")
                file_count=$((file_count + 1))
            done

            # Always add core context docs as read-only
            [[ -f ".context/guardrails.md" ]] && aider_file_args+=(--read ".context/guardrails.md")
            [[ -f ".context/core.md" ]] && aider_file_args+=(--read ".context/core.md")
            [[ -f "CLAUDE.md" ]] && aider_file_args+=(--read "CLAUDE.md")

            # Use subtree-only ONLY as fallback when no files were discovered
            # (--subtree-only and --file cannot be used together)
            if [[ $file_count -eq 0 && -n "$aider_subtree" ]]; then
                aider_extra_args+=(--subtree-only "$aider_subtree")
                echo "[$name] No files discovered, using subtree: $aider_subtree" >&2
            elif [[ $file_count -gt 0 ]]; then
                echo "[$name] Auto-discovered $file_count files for analysis" >&2
            fi

            # FIX 5: Inject file contents directly into prompt
            # This ensures models that can't use --file (DeepSeek, Grok, Llama) still see content
            prompt_with_files=$(inject_file_contents "$prompt_content" "$all_files")

            run_agent "$name" "$outfile" aider \
                --model "$model" \
                --message "$prompt_with_files" \
                "${aider_file_args[@]}" \
                "${aider_extra_args[@]}" \
                --no-auto-commits \
                --no-dirty-commits \
                --dry-run \
                --yes-always \
                --no-stream \
                --no-pretty \
                --no-fancy-input \
                --map-tokens 2048 &
            ;;
        ollama)
            # Use Ollama API with streaming for proper idle timeout detection
            # Build JSON payload safely using jq (stream: true for incremental output)
            payload_file="$WORK_DIR/payload_${i}.json"
            jq -n --arg model "$model" --arg prompt "$prompt_content" \
                '{model: $model, prompt: $prompt, stream: true}' > "$payload_file"
            # Wrapper script to call curl with streaming and extract response tokens
            wrapper_script="$WORK_DIR/ollama_wrapper_${i}.sh"
            cat > "$wrapper_script" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# Stream response and extract tokens as they arrive (enables idle timeout detection)
curl -sN http://127.0.0.1:11434/api/generate -d "@$1" | while IFS= read -r line; do
    # Extract response token from each JSON line
    token=$(echo "$line" | jq -r '.response // empty' 2>/dev/null)
    if [[ -n "$token" ]]; then
        printf '%s' "$token"
    fi
    # Check for error
    error=$(echo "$line" | jq -r '.error // empty' 2>/dev/null)
    if [[ -n "$error" ]]; then
        echo "Error: $error" >&2
    fi
done
echo ""  # Final newline
WRAPPER_EOF
            chmod +x "$wrapper_script"
            run_agent "$name" "$outfile" "$wrapper_script" "$payload_file" &
            ;;
        *)
            echo "Warning: Unknown agent type '$type' for $name" >&2
            continue
            ;;
    esac
    AGENT_PIDS+=($!)
    AGENT_TYPES+=("$type")
    AGENT_STATUSES+=("running")

    # Concurrency control: wait if we've hit the limit before launching next agent
    if [[ $MAX_CONCURRENCY -gt 0 ]]; then
        while true; do
            running=0
            for ((j=0; j<${#AGENT_PIDS[@]}; j++)); do
                if [[ "${AGENT_STATUSES[$j]}" == "running" ]] && kill -0 "${AGENT_PIDS[$j]}" 2>/dev/null; then
                    running=$((running + 1))
                fi
            done
            if [[ $running -lt $MAX_CONCURRENCY ]]; then
                break  # Slot available, proceed to launch next agent
            fi
            sleep 1  # Wait for a slot to open up
        done
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# FIX 4: Output Quality Detection
# ═══════════════════════════════════════════════════════════════════════════════

# Check if agent output is garbage (hallucinations, missing context, etc.)
# Returns: 0=quality OK, 1=garbage detected
# Sets QUALITY_WARNING variable with description if issues found
check_output_quality() {
    local outfile="$1"
    local name="$2"
    QUALITY_WARNING=""

    [[ ! -f "$outfile" || ! -s "$outfile" ]] && return 0  # Empty is not garbage, just empty

    # Check for excessive repetition (hallucination pattern like "[API] [API] [API]...")
    # Count repeated tokens - if same 3+ char token appears 50+ times, likely garbage
    local repetition_count
    repetition_count=$(grep -oE '\[[A-Z]{2,}\]' "$outfile" 2>/dev/null | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
    if [[ -n "$repetition_count" && "$repetition_count" -ge 50 ]]; then
        QUALITY_WARNING="excessive repetition detected (possible hallucination)"
        return 1
    fi

    # Check for "I don't have access" type responses (agent couldn't read files)
    if grep -qiE "don.t have access|cannot access|not provided|files not found|currently don.t have|I.m sorry.*(but|however)" "$outfile" 2>/dev/null; then
        # Only flag if output is short (long output with this phrase is probably OK)
        local line_count
        line_count=$(wc -l < "$outfile" 2>/dev/null | tr -d ' ')
        if [[ "$line_count" -lt 100 ]]; then
            QUALITY_WARNING="agent reported missing file access"
            return 1
        fi
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# Simple Progress Monitoring (scrolling output)
# ═══════════════════════════════════════════════════════════════════════════════

GLOBAL_START=$(date +%s)
any_failed=0
agents_running=${#AGENT_PIDS[@]}

# Print header with agent list
printf "${C_CYAN}Running %d agents:${C_RESET} %s\n" "${#AGENT_NAMES[@]}" "${AGENT_NAMES[*]}"
if [[ ${#SKIPPED_AGENTS[@]} -gt 0 ]]; then
    skip_reason=""
    if [[ "$WEB_ONLY" == "true" && "$REASONING_ONLY" == "true" ]]; then
        skip_reason="no web access or code-only"
    elif [[ "$WEB_ONLY" == "true" ]]; then
        skip_reason="no web access"
    elif [[ "$REASONING_ONLY" == "true" ]]; then
        skip_reason="code-only"
    fi
    printf "${C_DIM}Skipped (%s): %s${C_RESET}\n" "$skip_reason" "${SKIPPED_AGENTS[*]}"
fi
echo ""

# Monitor agents - print status as each completes
while [[ $agents_running -gt 0 ]]; do
    sleep 1

    for ((i=0; i<${#AGENT_PIDS[@]}; i++)); do
        if [[ "${AGENT_STATUSES[$i]}" == "running" ]]; then
            if ! kill -0 "${AGENT_PIDS[$i]}" 2>/dev/null; then
                # Agent just finished
                now=$(date +%s)
                elapsed=$((now - AGENT_START_TIMES[$i]))
                wait "${AGENT_PIDS[$i]}" 2>/dev/null
                exit_code=$?
                AGENT_ELAPSED[$i]=$elapsed

                if [[ $exit_code -eq 0 ]]; then
                    # FIX 4: Check output quality even for successful agents
                    if check_output_quality "${AGENT_OUTFILES[$i]}" "${AGENT_NAMES[$i]}"; then
                        AGENT_STATUSES[$i]="done"
                        printf "${C_GREEN}${SYM_CHECK}${C_RESET} ${C_BOLD}%s${C_RESET} completed (%s)\n" \
                            "${AGENT_NAMES[$i]}" "$(format_elapsed "$elapsed")"
                    else
                        AGENT_STATUSES[$i]="low_quality"
                        printf "${C_YELLOW}⚠${C_RESET} ${C_BOLD}%s${C_RESET} completed with warnings (%s) - %s\n" \
                            "${AGENT_NAMES[$i]}" "$(format_elapsed "$elapsed")" "$QUALITY_WARNING"
                    fi
                elif [[ $exit_code -eq 124 ]]; then
                    AGENT_STATUSES[$i]="idle_timeout"
                    any_failed=1
                    printf "${C_RED}${SYM_CROSS}${C_RESET} ${C_BOLD}%s${C_RESET} idle timeout (%s)\n" \
                        "${AGENT_NAMES[$i]}" "$(format_elapsed "$elapsed")"
                elif [[ $exit_code -eq 125 ]]; then
                    AGENT_STATUSES[$i]="hard_timeout"
                    any_failed=1
                    printf "${C_RED}${SYM_CROSS}${C_RESET} ${C_BOLD}%s${C_RESET} hard timeout (%s)\n" \
                        "${AGENT_NAMES[$i]}" "$(format_elapsed "$elapsed")"
                else
                    AGENT_STATUSES[$i]="failed"
                    any_failed=1
                    printf "${C_RED}${SYM_CROSS}${C_RESET} ${C_BOLD}%s${C_RESET} failed (%s)\n" \
                        "${AGENT_NAMES[$i]}" "$(format_elapsed "$elapsed")"
                fi
                agents_running=$((agents_running - 1))
            fi
        fi
    done
done
global_elapsed=$(($(date +%s) - GLOBAL_START))
success_count=0
warn_count=0
fail_count=0
for status in "${AGENT_STATUSES[@]}"; do
    if [[ "$status" == "done" ]]; then
        success_count=$((success_count + 1))
    elif [[ "$status" == "low_quality" ]]; then
        warn_count=$((warn_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
done

echo ""
if [[ $warn_count -gt 0 ]]; then
    printf "${C_GREEN}${SYM_STAR} All agents complete${C_RESET} | ${C_GREEN}%d success${C_RESET} / ${C_YELLOW}%d warnings${C_RESET} / ${C_RED}%d failed${C_RESET} | %s\n" \
        "$success_count" "$warn_count" "$fail_count" "$(format_elapsed "$global_elapsed")"
else
    printf "${C_GREEN}${SYM_STAR} All agents complete${C_RESET} | ${C_GREEN}%d success${C_RESET} / ${C_RED}%d failed${C_RESET} | %s\n" \
        "$success_count" "$fail_count" "$(format_elapsed "$global_elapsed")"
fi

# Post-process Gemini output to filter startup noise
for mapping in "${GEMINI_RAW_FILES[@]}"; do
    raw_file="${mapping%%:*}"
    final_file="${mapping##*:}"
    if [[ -f "$raw_file" ]]; then
        # Filter common Gemini CLI noise patterns (case-insensitive)
        grep -viE '^\[STARTUP\]|^Loaded cached|^YOLO mode|^Using model|^Initializing' "$raw_file" > "$final_file" 2>/dev/null || cp "$raw_file" "$final_file"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# Save results to markdown file
# ═══════════════════════════════════════════════════════════════════════════════

# Generate filename from timestamp and slugified prompt
TIMESTAMP=$(date +%Y%m%d-%H%M)
PROMPT_SLUG=$(slugify "$1")
RESULTS_FILE="$RESULTS_DIR/${TIMESTAMP}-${PROMPT_SLUG}.md"

# Write markdown file
{
    echo "# Agent Comparison Results"
    echo ""
    echo "**Date:** $(date '+%Y-%m-%d %H:%M:%S')"
    if [[ $warn_count -gt 0 ]]; then
        echo "**Agents:** ${#AGENT_NAMES[@]} (${success_count} succeeded, ${warn_count} warnings, ${fail_count} failed)"
    else
        echo "**Agents:** ${#AGENT_NAMES[@]} (${success_count} succeeded, ${fail_count} failed)"
    fi
    echo "**Total Time:** $(format_elapsed "$global_elapsed")"
    echo "**Git HEAD:** $(git rev-parse --short HEAD 2>/dev/null || echo 'N/A')"
    echo "**Branch:** $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'N/A')"
    echo ""
    echo "## Summary"
    echo ""
    echo "| Agent | Status | Time | Output |"
    echo "|-------|--------|------|--------|"
    for ((i=0; i<${#AGENT_NAMES[@]}; i++)); do
        status_emoji="✅"
        [[ "${AGENT_STATUSES[$i]}" == "low_quality" ]] && status_emoji="⚠️"
        [[ "${AGENT_STATUSES[$i]}" != "done" && "${AGENT_STATUSES[$i]}" != "low_quality" ]] && status_emoji="❌"
        output_size="0B"
        if [[ -f "${AGENT_OUTFILES[$i]}" ]]; then
            bytes=$(wc -c < "${AGENT_OUTFILES[$i]}" 2>/dev/null | tr -d ' ')
            if [[ $bytes -gt 1024 ]]; then
                output_size="$((bytes / 1024))KB"
            else
                output_size="${bytes}B"
            fi
        fi
        printf "| %s | %s %s | %s | %s |\n" \
            "${AGENT_NAMES[$i]}" \
            "$status_emoji" \
            "${AGENT_STATUSES[$i]}" \
            "$(format_elapsed "${AGENT_ELAPSED[$i]}")" \
            "$output_size"
    done
    echo ""
    echo "## Prompt"
    echo ""
    echo '```'
    echo "$1"
    echo '```'
    # Show expanded prompt if git refs were resolved
    if [[ -f "$PROMPT_FILE" ]] && grep -q "=== Expanded Git References ===" "$PROMPT_FILE" 2>/dev/null; then
        echo ""
        echo "## Expanded Prompt (with git refs)"
        echo ""
        echo '```'
        cat "$PROMPT_FILE"
        echo '```'
    fi
    echo ""
    echo "---"
    echo ""

    # Write each agent's response
    for ((i=0; i<${#AGENT_NAMES[@]}; i++)); do
        status_icon="✓"
        [[ "${AGENT_STATUSES[$i]}" == "low_quality" ]] && status_icon="⚠"
        [[ "${AGENT_STATUSES[$i]}" != "done" && "${AGENT_STATUSES[$i]}" != "low_quality" ]] && status_icon="✗"

        echo "## ${status_icon} ${AGENT_NAMES[$i]}"
        echo ""
        echo "**Status:** ${AGENT_STATUSES[$i]} | **Time:** $(format_elapsed "${AGENT_ELAPSED[$i]}")"
        echo ""

        if [[ -f "${AGENT_OUTFILES[$i]}" && -s "${AGENT_OUTFILES[$i]}" ]]; then
            echo '```'
            cat "${AGENT_OUTFILES[$i]}"
            echo '```'
        else
            echo "*No output*"
        fi
        echo ""
        echo "---"
        echo ""
    done
} > "$RESULTS_FILE"

echo ""
echo "Results saved to: $RESULTS_FILE"

# Propagate failure if any agent failed
if [[ $any_failed -ne 0 ]]; then
    echo "Warning: One or more agents failed or timed out" >&2
    exit 1
fi

exit 0

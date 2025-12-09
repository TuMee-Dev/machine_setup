#!/bin/zsh

set -eo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

OLLAMA_API="http://localhost:11434/api/chat"

# Tool definition for testing (single line to avoid heredoc issues)
TOOL_JSON='{"type":"function","function":{"name":"get_current_weather","description":"Get the current weather for a location","parameters":{"type":"object","properties":{"location":{"type":"string","description":"The city"}},"required":["location"]}}}'

usage() {
    echo "Usage: $0 <pattern>"
    echo ""
    echo "Arguments:"
    echo "  --all                 Test all installed models"
    echo "  <substring>           Test only models matching the substring"
    echo ""
    echo "Examples:"
    echo "  $0 --all              Test all installed models"
    echo "  $0 qwen               Test only models containing 'qwen'"
    echo "  $0 :32b               Test only 32b models"
}

# Test if a model supports tool calling
test_tool_support() {
    local model_name="$1"

    # Build JSON without heredoc to avoid newline issues
    local request_json="{\"model\":\"$model_name\",\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Paris?\"}],\"tools\":[$TOOL_JSON],\"stream\":false}"

    # Make the API call
    local response=$(curl -s -X POST "$OLLAMA_API" \
        -H "Content-Type: application/json" \
        -d "$request_json" 2>/dev/null)

    # Check if response contains tool_calls (use printf to avoid echo interpreting escapes)
    if printf '%s' "$response" | jq -e '.message.tool_calls' >/dev/null 2>&1; then
        local tool_calls=$(printf '%s' "$response" | jq -r '.message.tool_calls')
        if [[ "$tool_calls" != "null" && "$tool_calls" != "[]" ]]; then
            return 0  # Supports tools
        fi
    fi

    return 1  # Does not support tools
}

# Get list of installed models
get_installed_models() {
    ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v '^$'
}

main() {
    local pattern=""

    # Parse arguments
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    # If multiple args or arg contains path separators, user likely typed * and shell expanded it
    if [[ $# -gt 1 ]] || [[ "$1" == */* ]] || [[ "$1" == *.csv ]] || [[ "$1" == *.sh ]]; then
        pattern="--all"
    else
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            --all)
                pattern="--all"
                ;;
            *)
                pattern="$1"
                ;;
        esac
    fi

    # Check dependencies
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}[ERROR]${NC} jq is required but not installed"
        exit 1
    fi

    if ! command -v ollama &> /dev/null; then
        echo -e "${RED}[ERROR]${NC} ollama is not installed or not in PATH"
        exit 1
    fi

    # Check if Ollama is running
    if ! curl -s "$OLLAMA_API" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR]${NC} Ollama server is not running. Start it with: ollama serve"
        exit 1
    fi

    # Get models
    local models=$(get_installed_models)

    if [[ -z "$models" ]]; then
        echo -e "${YELLOW}[WARNING]${NC} No models installed"
        exit 0
    fi

    # Apply pattern filter (unless --all)
    if [[ "$pattern" != "--all" ]]; then
        models=$(echo "$models" | grep -i "$pattern" || true)
        if [[ -z "$models" ]]; then
            echo -e "${YELLOW}[WARNING]${NC} No models match pattern: $pattern"
            exit 0
        fi
        echo -e "${BLUE}[INFO]${NC} Testing models matching: $pattern"
    else
        echo -e "${BLUE}[INFO]${NC} Testing all models"
    fi

    local model_count=$(echo "$models" | wc -l | tr -d ' ')
    echo -e "${BLUE}[INFO]${NC} Testing $model_count model(s) for tool support..."
    echo ""

    # Print header
    printf "%-40s %s\n" "Model" "Tools"
    printf "%-40s %s\n" "────────────────────────────────────────" "─────"

    local supports_count=0
    local no_support_count=0

    while IFS= read -r model; do
        [[ -z "$model" ]] && continue

        # Show progress
        printf "%-40s " "$model"

        if test_tool_support "$model"; then
            echo -e "${GREEN}✓${NC}"
            supports_count=$((supports_count + 1))
        else
            echo -e "${RED}✗${NC}"
            no_support_count=$((no_support_count + 1))
        fi
    done <<< "$models"

    # Summary
    echo ""
    echo -e "${BLUE}[SUMMARY]${NC}"
    echo -e "  Tool support:    ${GREEN}$supports_count${NC}"
    echo -e "  No tool support: ${RED}$no_support_count${NC}"
}

main "$@"

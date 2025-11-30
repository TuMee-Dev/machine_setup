#!/bin/zsh

set -eo pipefail

# ---------------------------------------
# PATHS
# ---------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_SKILLS_DIR="${SCRIPT_DIR}/../skills"

# Canonical local store
CANONICAL_SKILLS_DIR="$HOME/.skills"

# Symlink targets
OPENCODE_SKILLS_DIR="$HOME/.config/opencode/skills"
CLAUDE_CODE_SKILLS_DIR="$HOME/.claude/skills"

OPENCODE_CONFIG_FILE="$HOME/.config/opencode/config.json"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ---------------------------------------
# CHECK FOR opencode-skills PLUGIN
# ---------------------------------------
check_opencode_plugin() {
    log_info "Checking for opencode-skills plugin..."

    if ! npm list -g --depth=0 2>/dev/null | grep -q "opencode-skills"; then
        log_info "opencode-skills not found, installing..."
        npm install -g opencode-skills
        log_success "opencode-skills installed"
    else
        log_success "opencode-skills is already installed"
    fi
}

# ---------------------------------------
# ENSURE OpenCode CONFIG HAS THE PLUGIN ENABLED
# ---------------------------------------
configure_opencode_plugin() {
    log_info "Checking OpenCode configuration..."

    mkdir -p "$(dirname "$OPENCODE_CONFIG_FILE")"

    if [[ ! -f "$OPENCODE_CONFIG_FILE" ]]; then
        log_info "Creating new OpenCode config at $OPENCODE_CONFIG_FILE"
        echo '{"plugin": ["opencode-skills"]}' | jq . > "$OPENCODE_CONFIG_FILE"
        log_success "Config created"
    elif ! jq -e '.plugin | index("opencode-skills")' "$OPENCODE_CONFIG_FILE" >/dev/null 2>&1; then
        log_info "Adding opencode-skills to existing config..."
        jq '.plugin = ((.plugin // []) + ["opencode-skills"] | unique)' "$OPENCODE_CONFIG_FILE" > "$OPENCODE_CONFIG_FILE.tmp" \
            && mv "$OPENCODE_CONFIG_FILE.tmp" "$OPENCODE_CONFIG_FILE"
        log_success "Config updated"
    else
        log_success "opencode-skills already enabled in config"
    fi
}

# ---------------------------------------
# SYNC SKILLS TO CANONICAL STORE
# ---------------------------------------
sync_skills_to_canonical() {
    log_info "Syncing skills to canonical store ($CANONICAL_SKILLS_DIR)..."

    mkdir -p "$CANONICAL_SKILLS_DIR"

    # Repo skills overwrite conflicts, local-only skills preserved
    rsync -av "$REPO_SKILLS_DIR/" "$CANONICAL_SKILLS_DIR/"

    log_success "Skills synced to canonical store"
}

# ---------------------------------------
# CREATE SYMLINK TO CANONICAL STORE
# ---------------------------------------
link_skills_dir() {
    local target_dir="$1"
    local target_name="$2"

    log_info "Linking $target_name to canonical store..."

    mkdir -p "$(dirname "$target_dir")"

    if [[ -L "$target_dir" ]]; then
        local current=$(readlink "$target_dir")
        if [[ "$current" == "$CANONICAL_SKILLS_DIR" ]]; then
            log_success "$target_name already linked"
            return 0
        else
            log_warning "$target_name points elsewhere ($current), updating..."
            rm "$target_dir"
        fi
    elif [[ -d "$target_dir" ]]; then
        log_warning "$target_name is a directory, checking for local-only skills first..."
        # Move any local-only skills to canonical before replacing
        for skill_dir in "$target_dir"/*/; do
            [[ -d "$skill_dir" ]] || continue
            local skill_name=$(basename "$skill_dir")
            [[ "$skill_name" == .* ]] && continue
            if [[ ! -d "$CANONICAL_SKILLS_DIR/$skill_name" ]]; then
                log_info "Preserving local skill: $skill_name"
                cp -r "$skill_dir" "$CANONICAL_SKILLS_DIR/"
            fi
        done
        rm -rf "$target_dir"
    fi

    ln -s "$CANONICAL_SKILLS_DIR" "$target_dir"
    log_success "$target_name linked → $CANONICAL_SKILLS_DIR"
}

# ---------------------------------------
# DETECT LOCAL-ONLY SKILLS (canonical vs repo)
# ---------------------------------------
check_local_only_skills() {
    log_info "Checking for local-only skills..."

    local -a local_only=()

    for skill_dir in "$CANONICAL_SKILLS_DIR"/*/; do
        [[ -d "$skill_dir" ]] || continue
        local skill_name=$(basename "$skill_dir")

        # Skip hidden directories
        [[ "$skill_name" == .* ]] && continue

        if [[ ! -d "$REPO_SKILLS_DIR/$skill_name" ]]; then
            local_only+=("$skill_name")
        fi
    done

    if [[ ${#local_only[@]} -eq 0 ]]; then
        log_success "All skills are tracked in the repository"
        return 0
    fi

    echo ""
    log_warning "Found ${#local_only[@]} local-only skill(s):"
    for skill in "${local_only[@]}"; do
        echo "  - $skill"
    done
    echo ""

    read -p "Add these to the repository? [y/N] " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for skill in "${local_only[@]}"; do
            log_info "Copying $skill to repository..."
            cp -r "$CANONICAL_SKILLS_DIR/$skill" "$REPO_SKILLS_DIR/"
        done

        log_success "Skills copied to $REPO_SKILLS_DIR"
        echo ""
        log_info "Remember to commit and push this repository to sync across machines"
    else
        log_info "Skipped adding local skills to repository"
    fi
}

# ---------------------------------------
# MAIN
# ---------------------------------------
main() {
    log_info "Skills Sync Script"
    log_info "=================="
    echo ""

    # Check dependencies
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed. Install with: brew install jq"
        exit 1
    fi

    if ! command -v rsync &> /dev/null; then
        log_error "rsync is not installed"
        exit 1
    fi

    if ! command -v npm &> /dev/null; then
        log_error "npm is not installed"
        exit 1
    fi

    # Ensure repo skills directory exists
    mkdir -p "$REPO_SKILLS_DIR"

    # OpenCode plugin setup
    log_info "=== OpenCode Plugin Setup ==="
    check_opencode_plugin
    echo ""
    configure_opencode_plugin
    echo ""

    # Sync repo to canonical store
    log_info "=== Syncing Skills ==="
    sync_skills_to_canonical
    echo ""

    # Create symlinks from tool locations to canonical
    log_info "=== Creating Symlinks ==="
    link_skills_dir "$OPENCODE_SKILLS_DIR" "OpenCode"
    link_skills_dir "$CLAUDE_CODE_SKILLS_DIR" "Claude Code"
    echo ""

    # Check for local-only skills
    log_info "=== Local-Only Skills Check ==="
    check_local_only_skills

    echo ""
    log_success "Skills sync complete!"
    echo "  Canonical:   $CANONICAL_SKILLS_DIR"
    echo "  OpenCode:    $OPENCODE_SKILLS_DIR → $CANONICAL_SKILLS_DIR"
    echo "  Claude Code: $CLAUDE_CODE_SKILLS_DIR → $CANONICAL_SKILLS_DIR"
}

main "$@"

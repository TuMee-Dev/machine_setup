#!/bin/zsh

set -eo pipefail

CSV_FILE="ollama.csv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV_PATH="${SCRIPT_DIR}/${CSV_FILE}"

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

# Parse size strings (e.g., "8gb", "512gb", "1tb") to GB
parse_size_to_gb() {
    local size_str="$1"
    size_str=$(echo "$size_str" | tr '[:upper:]' '[:lower:]')

    if [[ $size_str =~ ^([0-9]+)(gb|tb)$ ]]; then
        local value="${match[1]}"
        local unit="${match[2]}"

        if [[ "$unit" == "tb" ]]; then
            echo $((value * 1024))
        else
            echo "$value"
        fi
    else
        echo "0"
    fi
}

# Get system RAM in GB
get_system_ram_gb() {
    local ram_bytes=$(sysctl -n hw.memsize)
    echo $((ram_bytes / 1024 / 1024 / 1024))
}

# Get base disk size in GB (total capacity, not used space)
# Rounds up to nearest 128GB increment (Apple's common disk sizes)
get_base_disk_size_gb() {
    local disk_info=$(diskutil info / | grep -i "Disk Size" | head -1)
    local raw_size=0

    if [[ $disk_info =~ ([0-9.]+)\ TB ]]; then
        local tb_value="${match[1]}"
        raw_size=$(printf "%.0f" "$(echo "$tb_value * 1024" | bc)")
    elif [[ $disk_info =~ ([0-9.]+)\ GB ]]; then
        raw_size=$(printf "%.0f" "${match[1]}")
    fi

    # Round up to nearest 128GB
    if [[ $raw_size -gt 0 ]]; then
        echo $(( ((raw_size + 127) / 128) * 128 ))
    else
        echo "0"
    fi
}

# Get available disk space in GB
get_available_disk_gb() {
    local available_bytes=$(df -k / | tail -1 | awk '{print $4}')
    echo $((available_bytes / 1024 / 1024))
}

# Verify system meets requirements for a model
verify_system_requirements() {
    local required_ram_str="$1"
    local required_disk_str="$2"
    local model_name="$3"

    local required_ram_gb=$(parse_size_to_gb "$required_ram_str")
    local required_disk_gb=$(parse_size_to_gb "$required_disk_str")

    local system_ram_gb=$(get_system_ram_gb)
    local system_disk_gb=$(get_base_disk_size_gb)

    local ram_ok=false
    local disk_ok=false

    if [[ $system_ram_gb -ge $required_ram_gb ]]; then
        ram_ok=true
    fi

    if [[ $system_disk_gb -ge $required_disk_gb ]]; then
        disk_ok=true
    fi

    if [[ "$ram_ok" == true && "$disk_ok" == true ]]; then
        return 0
    else
        local reasons=""
        [[ "$ram_ok" == false ]] && reasons="RAM: ${system_ram_gb}/${required_ram_gb}GB"
        if [[ "$disk_ok" == false ]]; then
            [[ -n "$reasons" ]] && reasons="${reasons}, " || reasons=""
            reasons="${reasons}Disk: ${system_disk_gb}/${required_disk_gb}GB"
        fi
        log_warning "Skipping $model_name ($reasons)" >&2
        return 1
    fi
}

# Check if model is already downloaded
is_model_downloaded() {
    local model_name="$1"
    ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -Fxq "$model_name" && return 0 || return 1
}

# Pull model with infinite retry
pull_model_with_retry() {
    local model_name="$1"
    local required_disk_str="$2"

    log_info "Downloading model: $model_name"

    while true; do
        # Check available disk space before each attempt
        local available_gb=$(get_available_disk_gb)
        local required_disk_gb=$(parse_size_to_gb "$required_disk_str")

        # Rough estimate: model size is ~half of minimum_disk requirement
        local estimated_model_gb=$((required_disk_gb / 20))

        if [[ $available_gb -lt $estimated_model_gb ]]; then
            log_error "Insufficient disk space for $model_name (${available_gb}GB available, ~${estimated_model_gb}GB needed)"
            log_error "Free up space and press Enter to retry..."
            read -r
            continue
        fi

        if ollama pull "$model_name"; then
            log_success "Successfully downloaded: $model_name"
            return 0
        else
            log_warning "Failed to download $model_name, retrying in 5 seconds..."
            sleep 5
        fi
    done
}

# Parse CSV and return list of eligible models
get_eligible_models() {
    local -a models=()
    typeset -A seen_models  # Track unique models to avoid duplicates

    while IFS=, read -r category model_name min_memory min_disk description; do
        # Skip comments, empty lines, and header
        [[ "$category" =~ ^#.*$ ]] && continue
        [[ -z "$category" ]] && continue
        [[ "$category" == "category" ]] && continue

        # Skip if we've already seen this model
        [[ -n "${seen_models[$model_name]}" ]] && continue

        # Verify system requirements
        if verify_system_requirements "$min_memory" "$min_disk" "$model_name"; then
            models+=("$model_name|$min_disk")
            seen_models[$model_name]=1
        fi
    done < "$CSV_PATH"

    if [[ ${#models[@]} -gt 0 ]]; then
        printf '%s\n' "${models[@]}"
    fi
}

# Get list of currently installed models
get_installed_models() {
    ollama list | tail -n +2 | awk '{print $1}' | grep -v '^$'
}

# Remove models not in CSV
remove_unlisted_models() {
    local -a csv_models=()

    log_info "Checking for models not in CSV..."

    # Get all models from CSV
    while IFS=, read -r category model_name min_memory min_disk description; do
        [[ "$category" =~ ^#.*$ ]] && continue
        [[ -z "$category" ]] && continue
        [[ "$category" == "category" ]] && continue
        csv_models+=("$model_name")
    done < "$CSV_PATH"

    # Get installed models
    local installed_models=$(get_installed_models)

    local -a to_remove=()

    while IFS= read -r installed_model; do
        [[ -z "$installed_model" ]] && continue

        local found=false
        for csv_model in "${csv_models[@]}"; do
            if [[ "$installed_model" == "$csv_model" ]]; then
                found=true
                break
            fi
        done

        if [[ "$found" == false ]]; then
            to_remove+=("$installed_model")
        fi
    done <<< "$installed_models"

    if [[ ${#to_remove[@]} -eq 0 ]]; then
        log_success "No unlisted models to remove"
        return 0
    fi

    log_warning "Found ${#to_remove[@]} model(s) not in CSV:"
    for model in "${to_remove[@]}"; do
        echo "  - $model"
    done

    echo ""
    read -p "Remove these models? (y/N): " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for model in "${to_remove[@]}"; do
            log_info "Removing model: $model"
            if ollama rm "$model"; then
                log_success "Removed: $model"
            else
                log_error "Failed to remove: $model"
            fi
        done
    else
        log_info "Skipped model removal"
    fi
}

# Main function
main() {
    local cleanup_mode=false

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cleanup)
                cleanup_mode=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Usage: $0 [--cleanup]"
                echo "  --cleanup: Remove models not in CSV"
                exit 1
                ;;
        esac
    done

    log_info "Ollama Model Sync Script"
    log_info "========================"
    echo ""

    # Check if CSV exists
    if [[ ! -f "$CSV_PATH" ]]; then
        log_error "CSV file not found: $CSV_PATH"
        exit 1
    fi

    # Check if ollama is installed
    if ! command -v ollama &> /dev/null; then
        log_error "Ollama is not installed or not in PATH"
        exit 1
    fi

    # Display system info
    local system_ram=$(get_system_ram_gb)
    local system_disk=$(get_base_disk_size_gb)
    local available_disk=$(get_available_disk_gb)

    log_info "System Information:"
    echo "  RAM: ${system_ram}GB"
    echo "  Total Disk: ${system_disk}GB"
    echo "  Available Disk: ${available_disk}GB"
    echo ""

    # Get eligible models
    log_info "Analyzing models from CSV..."
    local eligible_models=$(get_eligible_models)

    if [[ -z "$eligible_models" ]]; then
        log_warning "No models meet system requirements"
        exit 0
    fi

    local model_count=$(echo "$eligible_models" | wc -l | tr -d ' ')
    log_info "Found $model_count eligible model(s) for this system"

    # Download models
    local downloaded_count=0
    local skipped_count=0

    while IFS='|' read -r model_name min_disk; do
        [[ -z "$model_name" ]] && continue
        if is_model_downloaded "$model_name"; then
            log_success "Already downloaded: $model_name"
            skipped_count=$((skipped_count + 1))
        else
            pull_model_with_retry "$model_name" "$min_disk"
            downloaded_count=$((downloaded_count + 1))
        fi
    done <<< "$eligible_models"

    echo ""
    log_success "Download phase complete!"
    echo "  Downloaded: $downloaded_count model(s)"
    echo "  Already local: $skipped_count model(s)"
    echo ""

    # Check for unlisted models if --cleanup flag is set
    if [[ "$cleanup_mode" == true ]]; then
        remove_unlisted_models
    fi

    echo ""
    log_success "All operations complete!"
}

main "$@"

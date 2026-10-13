#!/usr/bin/env bash

set -Eeuo pipefail

PIDX_FILE="${PIDX_FILE:-STMicroelectronics.pidx.txt}"
PIDX_CACHE_FILE="${PIDX_CACHE_FILE:-${PIDX_FILE}.cache}"
DRY_RUN="${DRY_RUN:-false}"
NO_REMOVE="${NO_REMOVE:-false}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/ws}"
SETTINGS_FILE="${SETTINGS_FILE:-$HOME/.theia-cubemx2/settings.json}"
BACKUP_FILE="${SETTINGS_FILE}.bak"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

EXPECTED_LIST_FILE="$TMP_DIR/expected.list"
INSTALLED_LIST_FILE="$TMP_DIR/installed.list"

TO_REMOVE_FILE="$TMP_DIR/to_remove.list"
TO_REMOVE_METADATA_FILE="$TMP_DIR/to_remove_metadata.list"
TO_INSTALL_FILE="$TMP_DIR/to_install.list"
PLAN_FILE="$TMP_DIR/plan.list"

removed_count=0
metadata_removed_count=0
installed_count=0
already_ok_count=0
skipped_count=0

script_start_ts="$(date +%s)"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

phase_start() {
    PHASE_NAME="$1"
    PHASE_TS="$(date +%s)"
    log "===== ${PHASE_NAME} ====="
}

phase_end() {
    local now elapsed
    now="$(date +%s)"
    elapsed=$((now - PHASE_TS))
    log "===== End ${PHASE_NAME} (${elapsed}s) ====="
}

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Error: '$cmd' command not found in PATH."
        exit 1
    }
}

version_ge() {
    local v1="$1"
    local v2="$2"

    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi

    local n1 n2
    n1="$(echo "$v1" | sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/')"
    n2="$(echo "$v2" | sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/')"

    [[ "$(printf '%s\n%s\n' "$n2" "$n1" | sort -V | tail -n1)" == "$n1" ]]
}

disable_pdsc_sync_on_startup() {
    local settings_dir
    settings_dir="$(dirname "$SETTINGS_FILE")"

    if [[ ! -d "$settings_dir" ]]; then
        log "Creating settings directory: $settings_dir"
        run_cmd mkdir -p "$settings_dir"
    fi

    if [[ ! -f "$SETTINGS_FILE" ]]; then
        log "Settings file not found, creating: $SETTINGS_FILE"
        cat > "$SETTINGS_FILE" <<'EOF'
{
  "cube.cube-core.sync-pdsc-repositories-on-startup": false
}
EOF
        log "File created: $SETTINGS_FILE"
        return 0
    fi

    cp "$SETTINGS_FILE" "$BACKUP_FILE"
    log "Backup created: $BACKUP_FILE"

    if grep -q '"cube\.cube-core\.sync-pdsc-repositories-on-startup"' "$SETTINGS_FILE"; then
        sed -i 's/"cube\.cube-core\.sync-pdsc-repositories-on-startup":[[:space:]]*true/"cube.cube-core.sync-pdsc-repositories-on-startup": false/g' "$SETTINGS_FILE"
        sed -i 's/"cube\.cube-core\.sync-pdsc-repositories-on-startup":[[:space:]]*false/"cube.cube-core.sync-pdsc-repositories-on-startup": false/g' "$SETTINGS_FILE"
        log "Updated existing sync setting in: $SETTINGS_FILE"
    else
        log "Sync setting not found, adding it to: $SETTINGS_FILE"

        awk '
        BEGIN { added=0 }
        /^[[:space:]]*}[[:space:]]*$/ && added==0 {
            print "  \"cube.cube-core.sync-pdsc-repositories-on-startup\": false"
            print $0
            added=1
            next
        }
        { print $0 }
        END {
            if (added==0) {
                print "{"
                print "  \"cube.cube-core.sync-pdsc-repositories-on-startup\": false"
                print "}"
            }
        }
        ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"

        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        log "Setting added to: $SETTINGS_FILE"
    fi
}

install_pack_manager() {
    run_cmd cube bundle install pack-manager --yes
}

build_pidx_cache() {
    local src_file="$1"
    local cache_file="$2"

    log "Building PIDX cache from: $src_file"

    awk '
    /<pdsc / {
        url=""; vendor=""; name=""; version="";

        if (match($0, /url="[^"]*"/)) {
            url = substr($0, RSTART + 5, RLENGTH - 6)
        }
        if (match($0, /vendor="[^"]*"/)) {
            vendor = substr($0, RSTART + 8, RLENGTH - 9)
        }
        if (match($0, /name="[^"]*"/)) {
            name = substr($0, RSTART + 6, RLENGTH - 7)
        }
        if (match($0, /version="[^"]*"/)) {
            version = substr($0, RSTART + 9, RLENGTH - 10)
        }

        gsub(/\r/, "", url)
        gsub(/\r/, "", vendor)
        gsub(/\r/, "", name)
        gsub(/\r/, "", version)

        if (url != "" && vendor != "" && name != "" && version != "") {
            pack_url = url vendor "." name "." version ".pack"
            print vendor "|" name "|" version "|" pack_url
        }
    }
    ' "$src_file" | sort -u > "$cache_file"
}

load_expected_data() {
    phase_start "Load expected packs from PIDX cache"

    if [[ ! -f "$PIDX_FILE" ]]; then
        log "Error: PIDX file not found: $PIDX_FILE"
        exit 1
    fi

    if [[ ! -f "$PIDX_CACHE_FILE" || "$PIDX_FILE" -nt "$PIDX_CACHE_FILE" ]]; then
        build_pidx_cache "$PIDX_FILE" "$PIDX_CACHE_FILE"
    else
        log "Using existing PIDX cache: $PIDX_CACHE_FILE"
    fi

    cp "$PIDX_CACHE_FILE" "$EXPECTED_LIST_FILE"

    if [[ ! -s "$EXPECTED_LIST_FILE" ]]; then
        log "Error: no valid pack entries found in the PIDX cache."
        exit 1
    fi

    log "Number of expected packs from PIDX: $(wc -l < "$EXPECTED_LIST_FILE" | tr -d ' ')"
    phase_end
}

get_installed_packs() {
    cube pack list packs | awk -F ' - ' '
    {
        gsub(/\r/, "", $0)

        pack_id = $1
        sub(/^[[:space:]]+/, "", pack_id)
        sub(/[[:space:]]+$/, "", pack_id)
        if (pack_id == "") {
            next
        }

        state = "installed"
        if (tolower($0) ~ /metadata[[:space:]]+only/) {
            state = "metadata_only"
        }

        if (!(pack_id in states) || state == "installed") {
            states[pack_id] = state
        }
    }
    END {
        for (pack_id in states) {
            print pack_id "|" states[pack_id]
        }
    }
    '
}

parse_installed_packs() {
    get_installed_packs | awk -F'|' '
    {
        line=$1
        state=$2
        gsub(/\r/, "", line)

        if (!match(line, /\.[0-9]/)) {
            next
        }

        index_version = RSTART
        prefix = substr(line, 1, index_version - 1)

        n = split(prefix, prefix_parts, ".")
        if (n < 2) {
            next
        }

        vendor = prefix_parts[1]

        name = prefix_parts[2]
        for (i = 3; i <= n; i++) {
            name = name "." prefix_parts[i]
        }

        version = substr(line, index_version + 1)

        print vendor "|" name "|" version "|" state
    }
    ' | sort -u
}

load_installed_data() {
    phase_start "Load installed packs"

    parse_installed_packs > "$INSTALLED_LIST_FILE"

    log "Installed packs detected: $(awk -F'|' '$4=="installed"{c++} END{print c+0}' "$INSTALLED_LIST_FILE")"
    log "Metadata-only entries detected: $(awk -F'|' '$4=="metadata_only"{c++} END{print c+0}' "$INSTALLED_LIST_FILE")"
    phase_end
}

compute_sync_plan() {
    phase_start "Compute synchronization plan"

    awk -F'|' '
    NR==FNR {
        vendor=$1
        name=$2
        version=$3
        url=$4

        vn=vendor "|" name
        fn=vendor "|" name "|" version

        expected_vendor[vn]=1
        expected_full[fn]=url
        next
    }
    {
        vendor=$1
        name=$2
        version=$3
        state=$4

        vn=vendor "|" name
        fn=vendor "|" name "|" version

        if (state == "installed") {
            installed[fn]=1
        }

        if (!(vn in expected_vendor)) {
            print "KEEP|" fn "|" state
        } else if (!(fn in expected_full)) {
            if (state == "metadata_only") {
                print "REMOVE_METADATA|" fn "|" state
            } else {
                print "REMOVE|" fn "|" state
            }
        } else if (state == "installed") {
            print "OK|" fn "|" state
        }
    }
    END {
        for (fn in expected_full) {
            if (!(fn in installed)) {
                print "INSTALL|" fn "|" expected_full[fn]
            }
        }
    }
    ' "$EXPECTED_LIST_FILE" "$INSTALLED_LIST_FILE" > "$PLAN_FILE"

    awk -F'|' '$1=="REMOVE"{print $2 "|" $3 "|" $4}' "$PLAN_FILE" | sort -u > "$TO_REMOVE_FILE"
    awk -F'|' '$1=="REMOVE_METADATA"{print $2 "|" $3 "|" $4}' "$PLAN_FILE" | sort -u > "$TO_REMOVE_METADATA_FILE"
    awk -F'|' '$1=="INSTALL"{print $2 "|" $3 "|" $4 "|" $5}' "$PLAN_FILE" | sort -u > "$TO_INSTALL_FILE"

    already_ok_count="$(awk -F'|' '$1=="OK" || ($1=="KEEP" && $5=="installed"){c++} END{print c+0}' "$PLAN_FILE")"

    log "Packs to remove           : $(wc -l < "$TO_REMOVE_FILE" | tr -d ' ')"
    log "Metadata-only to clean    : $(wc -l < "$TO_REMOVE_METADATA_FILE" | tr -d ' ')"
    log "Packs to install          : $(wc -l < "$TO_INSTALL_FILE" | tr -d ' ')"
    log "Packs already OK          : $already_ok_count"

    phase_end
}

remove_packs_with_cleanup() {
    local pack_count="$#"
    local cleanup_failed
    local failed_count=0

    if [[ "$NO_REMOVE" == "true" ]]; then
        log "Pack removal, cache and metadata cleanup disabled because NO_REMOVE=true"
        return 0
    fi

    if [[ "$pack_count" -eq 0 ]]; then
        return 0
    fi

    log "Removing $pack_count pack(s) with pack-manager."

    if ! run_cmd cube mx pack-manager remove --pack-ids "$@"; then
        skipped_count=$((skipped_count + pack_count))
        log "WARNING: batch removal failed; cache and metadata cleanup not attempted."
        return 1
    fi

    removed_count=$((removed_count + pack_count))

    for pack_id in "$@"; do
        cleanup_failed=0

        log "Removing caches for: $pack_id"
        if ! run_cmd cube pack remove --caches "$pack_id"; then
            log "WARNING: cache cleanup failed for: $pack_id"
            cleanup_failed=1
        fi

        log "Removing metadata for: $pack_id"
        if ! run_cmd cube pack remove --metadata "$pack_id"; then
            log "WARNING: metadata cleanup failed for: $pack_id"
            cleanup_failed=1
        fi

        if [[ "$cleanup_failed" -eq 0 ]]; then
            log "Pack removal and cleanup completed: $pack_id"
        else
            failed_count=$((failed_count + 1))
        fi
    done

    if [[ "$failed_count" -gt 0 ]]; then
        skipped_count=$((skipped_count + failed_count))
        log "WARNING: $failed_count removed pack(s) have incomplete cleanup."
        return 1
    fi

    return 0
}

remove_metadata_only_with_cleanup() {
    local cleanup_failed
    local failed_count=0

    if [[ "$NO_REMOVE" == "true" || "$#" -eq 0 ]]; then
        return 0
    fi

    for pack_id in "$@"; do
        cleanup_failed=0

        log "Removing caches for metadata-only entry: $pack_id"
        if ! run_cmd cube pack remove --caches "$pack_id"; then
            log "WARNING: cache cleanup failed for: $pack_id"
            cleanup_failed=1
        fi

        log "Removing metadata-only entry: $pack_id"
        if run_cmd cube pack remove --metadata "$pack_id"; then
            metadata_removed_count=$((metadata_removed_count + 1))
        else
            log "WARNING: metadata cleanup failed for: $pack_id"
            cleanup_failed=1
        fi

        if [[ "$cleanup_failed" -ne 0 ]]; then
            skipped_count=$((skipped_count + 1))
            failed_count=$((failed_count + 1))
        fi
    done

    [[ "$failed_count" -eq 0 ]]
}

remove_packs() {
    local pack_ids=()
    local metadata_ids=()
    local vendor
    local name
    local version
    local full_pack
    local pack_count
    local removal_failed=0

    if [[ "$NO_REMOVE" == "true" ]]; then
        log "Pack removal disabled because NO_REMOVE=true"
        return 0
    fi

    phase_start "Remove outdated packs"

    if [[ ! -s "$TO_REMOVE_FILE" && ! -s "$TO_REMOVE_METADATA_FILE" ]]; then
        log "No pack to remove."
        phase_end
        return 0
    fi

    while IFS='|' read -r vendor name version; do
        [[ -z "$vendor" || -z "$name" || -z "$version" ]] && continue
        full_pack="${vendor}.${name}.${version}"
        pack_ids+=("$full_pack")
        log "Queued for removal: $full_pack"
    done < "$TO_REMOVE_FILE"

    while IFS='|' read -r vendor name version; do
        [[ -z "$vendor" || -z "$name" || -z "$version" ]] && continue
        full_pack="${vendor}.${name}.${version}"
        metadata_ids+=("$full_pack")
        log "Queued metadata-only entry for cleanup: $full_pack"
    done < "$TO_REMOVE_METADATA_FILE"

    pack_count="${#pack_ids[@]}"

    if [[ "$pack_count" -eq 0 && "${#metadata_ids[@]}" -eq 0 ]]; then
        log "No valid pack or metadata-only entry to remove."
        phase_end
        return 0
    fi

    if [[ "$pack_count" -gt 0 ]]; then
        if remove_packs_with_cleanup "${pack_ids[@]}"; then
            log "Successfully removed $pack_count pack(s), including caches and metadata."
        else
            removal_failed=1
        fi
    fi

    if [[ "${#metadata_ids[@]}" -gt 0 ]]; then
        if remove_metadata_only_with_cleanup "${metadata_ids[@]}"; then
            log "Successfully cleaned ${#metadata_ids[@]} metadata-only entry/entries."
        else
            removal_failed=1
        fi
    fi

    if [[ "$removal_failed" -ne 0 ]]; then
        log "WARNING: pack removal or cleanup failed."
        phase_end
        return 1
    fi

    phase_end
}

remove_nucleo_c5q1zg_hw_board_v2_or_more() {
    local pack_ids=()
    local metadata_ids=()
    local vendor
    local name
    local version
    local state
    local full_pack
    local pack_count
    local removal_failed=0

    if [[ "$NO_REMOVE" == "true" ]]; then
        log "Pack removal disabled because NO_REMOVE=true"
        return 0
    fi

    phase_start "Remove STMicroelectronics.nucleo-c5q1zg_hw-board > 2.0.0"

    while IFS='|' read -r vendor name version state; do
        [[ -z "$vendor" || -z "$name" || -z "$version" ]] && continue

        if [[ "$vendor" == "STMicroelectronics" &&
              "$name" == "nucleo-c5q1zg_hw-board" ]]; then

            if version_ge "$version" "2.0.0" &&
               [[ "$version" != "2.0.0" ]]; then

                full_pack="${vendor}.${name}.${version}"
                log "Queued forbidden pack version > 2.0.0: $full_pack"

                if [[ "$state" == "metadata_only" ]]; then
                    metadata_ids+=("$full_pack")
                else
                    pack_ids+=("$full_pack")
                fi
            fi
        fi
    done < <(parse_installed_packs)

    pack_count="${#pack_ids[@]}"

    if [[ "$pack_count" -eq 0 && "${#metadata_ids[@]}" -eq 0 ]]; then
        log "No STMicroelectronics.nucleo-c5q1zg_hw-board pack with version > 2.0.0 found."
        phase_end
        return 0
    fi

    if [[ "$pack_count" -gt 0 ]]; then
        if remove_packs_with_cleanup "${pack_ids[@]}"; then
            log "Successfully removed $pack_count forbidden pack(s), including caches and metadata."
        else
            removal_failed=1
        fi
    fi

    if [[ "${#metadata_ids[@]}" -gt 0 ]]; then
        if remove_metadata_only_with_cleanup "${metadata_ids[@]}"; then
            log "Successfully cleaned ${#metadata_ids[@]} forbidden metadata-only entry/entries."
        else
            removal_failed=1
        fi
    fi

    if [[ "$removal_failed" -ne 0 ]]; then
        log "WARNING: forbidden pack removal or cleanup failed."
        phase_end
        return 1
    fi

    phase_end
}

install_packs() {
    local pack_ids=()
    local vendor
    local name
    local version
    local pack_url
    local full_pack
    local pack_count

    phase_start "Install expected packs"

    if [[ ! -s "$TO_INSTALL_FILE" ]]; then
        log "No pack to install."
        phase_end
        return 0
    fi

    while IFS='|' read -r vendor name version pack_url; do
        [[ -z "$vendor" || -z "$name" || -z "$version" || -z "$pack_url" ]] && continue

        full_pack="${vendor}.${name}.${version}"
        log "Queued for installation: $full_pack"
        log "URL: $pack_url"
        pack_ids+=("$pack_url")
    done < "$TO_INSTALL_FILE"

    pack_count="${#pack_ids[@]}"

    if [[ "$pack_count" -eq 0 ]]; then
        log "No valid pack to install."
        phase_end
        return 0
    fi

    log "Installing $pack_count pack(s) in one pack-manager operation."

    if run_cmd cube mx pack-manager install --pack-ids "${pack_ids[@]}"; then
        installed_count=$((installed_count + pack_count))
        log "Successfully installed $pack_count pack(s)."
    else
        skipped_count=$((skipped_count + pack_count))
        log "WARNING: batch installation failed for $pack_count pack(s)."
        phase_end
        return 1
    fi

    phase_end
}

cleanup_project_artifacts() {
    local project_location="$1"
    local project_name="$2"

    local project_file="${project_location}/${project_name}"
    local ioc2_file="${project_location}/${project_name}.ioc2"
    local project_dir="${project_location}/${project_name}/"

    if [[ -f "$project_file" ]]; then
        log "Removing existing project file: $project_file"
        run_cmd rm -f "$project_file"
    fi

    if [[ -f "$ioc2_file" ]]; then
        log "Removing existing ioc2 file: $ioc2_file"
        run_cmd rm -f "$ioc2_file"
    fi

    if [[ -d "$project_dir" ]]; then
        log "Removing existing project directory: $project_dir"
        run_cmd rm -rf "$project_dir"
    fi
}

create_projects() {
    phase_start "Create test projects"

    cleanup_project_artifacts "$WORKSPACE_DIR" "MyAppRE"
    run_cmd cube mx project create-from-board --cpn NUCLEO-C562RE --project-location "$WORKSPACE_DIR" --project-name MyAppRE

    cleanup_project_artifacts "$WORKSPACE_DIR" "MyApprc"
    run_cmd cube mx project create-from-board --cpn NUCLEO-c542rc --project-location "$WORKSPACE_DIR" --project-name MyApprc

    cleanup_project_artifacts "$WORKSPACE_DIR" "MyAppzg"
    run_cmd cube mx project create-from-board --cpn NUCLEO-c5a3zg --project-location "$WORKSPACE_DIR" --project-name MyAppzg

    phase_end
}

print_summary() {
    local end_ts total_s
    end_ts="$(date +%s)"
    total_s=$((end_ts - script_start_ts))

    log "===== Summary ====="
    echo
    echo "PIDX packs                : $(wc -l < "$EXPECTED_LIST_FILE" | tr -d ' ')"
    echo "Installed packs (last scan): $(awk -F'|' '$4=="installed"{c++} END{print c+0}' "$INSTALLED_LIST_FILE")"
    echo "Metadata only (last scan)  : $(awk -F'|' '$4=="metadata_only"{c++} END{print c+0}' "$INSTALLED_LIST_FILE")"
    echo "Packs removed              : $removed_count"
    echo "Metadata-only cleaned      : $metadata_removed_count"
    echo "Packs installed            : $installed_count"
    echo "Packs already OK           : $already_ok_count"
    echo "Packs skipped              : $skipped_count"
    echo "NO_REMOVE                  : $NO_REMOVE"
    echo "DRY_RUN                    : $DRY_RUN"
    echo "Total duration             : ${total_s}s"
    echo
}

main() {
    require_cmd cube
    require_cmd awk
    require_cmd sed
    require_cmd sort
    require_cmd mktemp

    install_pack_manager
    disable_pdsc_sync_on_startup

    load_expected_data
    load_installed_data
    compute_sync_plan
    remove_packs
    install_packs
    remove_nucleo_c5q1zg_hw_board_v2_or_more
    load_installed_data
    create_projects
    print_summary

    log "Synchronization completed."
}

main "$@"
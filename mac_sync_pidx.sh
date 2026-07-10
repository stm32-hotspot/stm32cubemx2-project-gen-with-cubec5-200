#!/usr/bin/env bash

set -Eeuo pipefail

PIDX_FILE="${PIDX_FILE:-STMicroelectronics.pidx.txt}"
PIDX_CACHE_FILE="${PIDX_CACHE_FILE:-${PIDX_FILE}.cache}"
DRY_RUN="${DRY_RUN:-false}"
NO_REMOVE="${NO_REMOVE:-false}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/tmp/ws}"
SETTINGS_FILE="${HOME}/.theia-cubemx2/settings.json"
BACKUP_FILE="${SETTINGS_FILE}.bak"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

EXPECTED_LIST_FILE="$TMP_DIR/expected.list"
INSTALLED_LIST_FILE="$TMP_DIR/installed.list"
TO_REMOVE_FILE="$TMP_DIR/to_remove.list"
TO_INSTALL_FILE="$TMP_DIR/to_install.list"
PLAN_FILE="$TMP_DIR/plan.list"

removed_count=0
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
    # if [[ ! -f "$SETTINGS_FILE" ]]; then
        # log "Warning: settings file not found: $SETTINGS_FILE"
        # return 0
    # fi

    # cp "$SETTINGS_FILE" "$BACKUP_FILE"
    # sed -i '' 's/"cube\.cube-core\.sync-pdsc-repositories-on-startup":[[:space:]]*true/"cube.cube-core.sync-pdsc-repositories-on-startup": false/g' "$SETTINGS_FILE"

    # log "File updated: $SETTINGS_FILE"
    # log "Backup created: $BACKUP_FILE"
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
        sed -i '' 's/"cube\.cube-core\.sync-pdsc-repositories-on-startup":[[:space:]]*true/"cube.cube-core.sync-pdsc-repositories-on-startup": false/g' "$SETTINGS_FILE"
        sed -i '' 's/"cube\.cube-core\.sync-pdsc-repositories-on-startup":[[:space:]]*false/"cube.cube-core.sync-pdsc-repositories-on-startup": false/g' "$SETTINGS_FILE"
        log "Updated existing sync setting in: $SETTINGS_FILE"
    else
        if grep -q '^[[:space:]]*{[[:space:]]*}[[:space:]]*$' "$SETTINGS_FILE"; then
            cat > "$SETTINGS_FILE" <<'EOF'
{
  "cube.cube-core.sync-pdsc-repositories-on-startup": false
}
EOF
        else
            awk '
            {
                lines[NR]=$0
            }
            END {
                last_non_empty=0
                for (i=1; i<=NR; i++) {
                    if (lines[i] ~ /[^[:space:]]/) {
                        last_non_empty=i
                    }
                }

                for (i=1; i<=NR; i++) {
                    if (i == last_non_empty && lines[i] ~ /^[[:space:]]*}[[:space:]]*$/) {
                        prev=lines[i-1]
                        if (prev !~ /,[[:space:]]*$/ && prev !~ /^[[:space:]]*{[[:space:]]*$/) {
                            sub(/[[:space:]]*$/, "", lines[i-1])
                            lines[i-1]=lines[i-1] ","
                        }
                        print "  \"cube.cube-core.sync-pdsc-repositories-on-startup\": false"
                    }
                    print lines[i]
                }
            }
            ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"

            mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        fi

        log "Setting added to: $SETTINGS_FILE"
    fi

}

install_pack_manager() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] cube bundle install pack-manager --yes"
        return 0
    fi

    cube bundle install pack-manager --yes
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
    cube pack list packs | awk -F ' - ' 'NF >= 1 && $1 != "" {print $1}'
}

parse_installed_packs() {
    get_installed_packs | awk '
    {
        line=$0
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

        print vendor "|" name "|" version
    }
    ' | sort -u
}

load_installed_data() {
    phase_start "Load installed packs"

    parse_installed_packs > "$INSTALLED_LIST_FILE"

    log "Number of installed packs detected: $(wc -l < "$INSTALLED_LIST_FILE" | tr -d ' ')"
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

        vn=vendor "|" name
        fn=vendor "|" name "|" version

        installed[fn]=1

        if (!(vn in expected_vendor)) {
            print "KEEP|" fn
        } else if (!(fn in expected_full)) {
            print "REMOVE|" fn
        } else {
            print "OK|" fn
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
    awk -F'|' '$1=="INSTALL"{print $2 "|" $3 "|" $4 "|" $5}' "$PLAN_FILE" | sort -u > "$TO_INSTALL_FILE"

    already_ok_count="$(awk -F'|' '$1=="OK" || $1=="KEEP"{c++} END{print c+0}' "$PLAN_FILE")"

    log "Packs to remove   : $(wc -l < "$TO_REMOVE_FILE" | tr -d ' ')"
    log "Packs to install  : $(wc -l < "$TO_INSTALL_FILE" | tr -d ' ')"
    log "Packs already OK  : $already_ok_count"

    phase_end
}

remove_packs() {
    if [[ "$NO_REMOVE" == "true" ]]; then
        log "Pack removal disabled because NO_REMOVE=true"
        return 0
    fi

    phase_start "Remove outdated packs"

    if [[ ! -s "$TO_REMOVE_FILE" ]]; then
        log "No pack to remove."
        phase_end
        return 0
    fi

    while IFS='|' read -r vendor name version; do
        [[ -z "$vendor" || -z "$name" || -z "$version" ]] && continue

        full_pack="${vendor}.${name}.${version}"

        log "Removing outdated/non-reference version for known vendor.name: $full_pack"
        if run_cmd cube pack remove "$full_pack"; then
        run_cmd cube pack remove --caches "$full_pack"
        run_cmd cube pack remove --metadata "$full_pack"
            ((removed_count+=1))
        else
            log "WARNING: failed to remove pack: $full_pack"
            ((skipped_count+=1))
        fi
    done < "$TO_REMOVE_FILE"

    phase_end
}

remove_nucleo_c5q1zg_hw_board_v2_or_more() {
    if [[ "$NO_REMOVE" == "true" ]]; then
        log "Pack removal disabled because NO_REMOVE=true"
        return 0
    fi

    phase_start "Remove STMicroelectronics.nucleo-c5q1zg_hw-board > 2.0.0"

    local found=0

    while IFS='|' read -r vendor name version; do
        [[ -z "$vendor" || -z "$name" || -z "$version" ]] && continue

        if [[ "$vendor" == "STMicroelectronics" && "$name" == "nucleo-c5q1zg_hw-board" ]]; then
            if version_ge "$version" "2.0.0" && [[ "$version" != "2.0.0" ]]; then
                found=1
                local full_pack="${vendor}.${name}.${version}"
                log "Removing forbidden pack version > 2.0.0: $full_pack"

                if run_cmd cube pack remove "$full_pack"; then
                    run_cmd cube pack remove --caches "$full_pack"
                    run_cmd cube pack remove --metadata "$full_pack"
                    ((removed_count+=1))
                else
                    log "WARNING: failed to remove pack: $full_pack"
                    ((skipped_count+=1))
                fi
            fi
        fi
    done < <(parse_installed_packs)

    if [[ "$found" -eq 0 ]]; then
        log "No STMicroelectronics.nucleo-c5q1zg_hw-board pack with version > 2.0.0 found."
    fi

    phase_end
}
install_packs() {
    phase_start "Install expected packs"

    if [[ ! -s "$TO_INSTALL_FILE" ]]; then
        log "No pack to install."
        phase_end
        return 0
    fi

    while IFS='|' read -r vendor name version pack_url; do
        [[ -z "$vendor" || -z "$name" || -z "$version" || -z "$pack_url" ]] && continue

        full_pack="${vendor}.${name}.${version}"

        log "Installing: $full_pack"
        log "URL: $pack_url"

        if run_cmd cube pack install "$pack_url"; then
            ((installed_count+=1))
        else
            log "WARNING: installation failed, skipping: $full_pack"
            ((skipped_count+=1))
        fi
    done < "$TO_INSTALL_FILE"

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

    mkdir -p "$WORKSPACE_DIR"

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
    echo "PIDX packs       : $(wc -l < "$EXPECTED_LIST_FILE" | tr -d ' ')"
    echo "Existing packs  : $(wc -l < "$INSTALLED_LIST_FILE" | tr -d ' ')"
    echo "Packs removed    : $removed_count"
    echo "Packs installed  : $installed_count"
    echo "Packs already OK : $already_ok_count"
    echo "Packs skipped    : $skipped_count"
    echo "NO_REMOVE        : $NO_REMOVE"
    echo "DRY_RUN          : $DRY_RUN"
    echo "Total duration   : ${total_s}s"
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

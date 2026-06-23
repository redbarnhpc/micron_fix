#!/usr/bin/env bash
#
# micron-fw-check.sh
#
# Scans NVMe devices for known-bad Micron firmware versions affected by the
# panic-state defect (7450 series: E2MU200, 7500 series: E3MQ000), and
# provides exact remediation commands. Installs nvme-cli if not present.
#
# Released by Red Barn HPC
# https://redbarnhpc.com
# Release date: 2026-06-19
#
# Must be run as root (or with sudo) to install packages and query NVMe devices.

set -uo pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_RELEASE_DATE="2026-06-19"

RED='\033[1;31m'
RESET='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'

# Known-bad firmware versions -> affected model family
declare -A BAD_FW=(
    ["E2MU200"]="Micron 7450 series"
    ["E3MQ000"]="Micron 7500 series"
)

# Known-bad firmware -> fixed firmware target
declare -A TARGET_FW=(
    ["E2MU200"]="E2MU300"
    ["E3MQ000"]="E3MQ005"
)

# Known-bad firmware -> firmware binary filename (inside the downloaded zip)
declare -A FW_BIN=(
    ["E2MU200"]="Micron_7450_E2MU300_release.ubi"
    ["E3MQ000"]="Micron_7500_E3MQ005_release.ubi"
)

# Known-bad firmware -> Micron download URL (zip containing the .ubi)
declare -A FW_URL=(
    ["E2MU200"]="https://assets.micron.com/adobe/assets/urn:aaid:aem:09a5aa0b-2dd0-42ec-90ec-1b5aa21f59bb/renditions/original/as/micron-7450-e2mu300-release-ubi.zip"
    ["E3MQ000"]="https://assets.micron.com/adobe/assets/urn:aaid:aem:8f57c338-6f7e-406b-91e0-6c250a026be3/renditions/original/as/micron-7500-e3mq005-release-ubi.zip"
)

# --- Require root ---
if [[ "${EUID}" -ne 0 ]]; then
    printf "${RED}\n"
    echo "========================================================"
    echo " ERROR: This script must be run as root."
    echo " Package installation and NVMe device queries require"
    echo " root privileges. Re-run with sudo:"
    echo
    echo "   sudo bash $0"
    echo "========================================================"
    printf "${RESET}\n"
    exit 1
fi

# --- Install nvme-cli if missing ---
install_nvme_cli() {
    if command -v nvme >/dev/null 2>&1; then
        echo "nvme-cli already installed: $(nvme version | head -n1)"
        return 0
    fi

    echo "nvme-cli not found. Detecting distro..."

    if [[ ! -f /etc/os-release ]]; then
        echo "Cannot detect distro: /etc/os-release not found." >&2
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_ID_LIKE="${ID_LIKE:-}"

    echo "Detected distro: ${DISTRO_ID} (ID_LIKE: ${DISTRO_ID_LIKE:-none})"

    case "${DISTRO_ID}" in
        ubuntu|debian)
            apt-get update -y
            apt-get install -y nvme-cli
            ;;
        rhel|centos|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y nvme-cli
            else
                yum install -y nvme-cli
            fi
            ;;
        sles|opensuse*|suse)
            zypper install -y nvme-cli
            ;;
        *)
            # fall back to ID_LIKE
            if [[ "${DISTRO_ID_LIKE}" == *debian* ]]; then
                apt-get update -y
                apt-get install -y nvme-cli
            elif [[ "${DISTRO_ID_LIKE}" == *rhel* || "${DISTRO_ID_LIKE}" == *fedora* ]]; then
                if command -v dnf >/dev/null 2>&1; then
                    dnf install -y nvme-cli
                else
                    yum install -y nvme-cli
                fi
            else
                echo "Unsupported or unrecognized distro: ${DISTRO_ID}. Install nvme-cli manually." >&2
                exit 1
            fi
            ;;
    esac

    if ! command -v nvme >/dev/null 2>&1; then
        echo "nvme-cli installation failed." >&2
        exit 1
    fi

    echo "nvme-cli installed: $(nvme version | head -n1)"
}

# --- Scan for affected firmware ---
scan_devices() {
    echo
    echo "Scanning NVMe devices..."
    echo

    if ! nvme list >/dev/null 2>&1; then
        echo "No NVMe devices found or nvme list failed." >&2
        return 1
    fi

    local nvme_list_output
    nvme_list_output=$(nvme list)

    local found_bad=0

    # nvme list -o json gives structured output, easier to parse reliably than column text
    nvme list -o json >/tmp/nvme_list.json 2>/dev/null

    if [[ -f /tmp/nvme_list.json ]] && command -v python3 >/dev/null 2>&1; then
        RESULT=$(python3 - <<'PYEOF'
import json
bad_fw = {"E2MU200": "Micron 7450 series", "E3MQ000": "Micron 7500 series"}
try:
    with open("/tmp/nvme_list.json") as f:
        data = json.load(f)
except Exception:
    print("PARSE_ERROR")
    raise SystemExit

devices = data.get("Devices", [])
flat = []
for d in devices:
    if "Subsystems" in d:
        for sub in d["Subsystems"]:
            for ctrl in sub.get("Controllers", []):
                flat.append(ctrl)
    else:
        flat.append(d)

hits = []
for dev in flat:
    fw = str(dev.get("Firmware", dev.get("FirmwareRev", ""))).strip()
    model = str(dev.get("ModelNumber", dev.get("Model", ""))).strip()
    node = str(dev.get("DevicePath", dev.get("Device", "")))
    serial = str(dev.get("SerialNumber", dev.get("Serial", "")))
    if fw in bad_fw:
        hits.append((node, model, serial, fw, bad_fw[fw]))

if hits:
    print("BAD_FOUND")
    for node, model, serial, fw, family in hits:
        print(f"{node}|{model}|{serial}|{fw}|{family}")
else:
    print("CLEAN")
PYEOF
)
        rm -f /tmp/nvme_list.json
    else
        RESULT="CLEAN"
    fi

    # Print nvme list, highlighting any line that contains the serial number of a bad drive
    echo
    if [[ "${RESULT}" == BAD_FOUND* ]]; then
        local bad_serials
        bad_serials=$(echo "${RESULT#BAD_FOUND$'\n'}" | awk -F'|' '{print $3}')

        while IFS= read -r line; do
            local is_bad=0
            for serial in ${bad_serials}; do
                if [[ "${line}" == *"${serial}"* ]]; then
                    is_bad=1
                    break
                fi
            done
            if [[ "${is_bad}" -eq 1 ]]; then
                printf "${RED}%s${RESET}\n" "${line}"
            else
                echo "${line}"
            fi
        done <<< "${nvme_list_output}"
    else
        echo "${nvme_list_output}"
    fi

    echo
    echo "----------------------------------------"
    echo "Checking for known-affected firmware versions..."
    echo "----------------------------------------"

    if [[ "${RESULT}" == PARSE_ERROR* ]]; then
        echo "Warning: could not parse nvme list JSON output. Falling back to manual review of 'nvme list' above." >&2
        return 0
    fi

    if [[ "${RESULT}" == BAD_FOUND* ]]; then
        found_bad=1
        echo
        printf "${RED}"
        printf '#%.0s' {1..58}; echo
        printf '#%-56s#\n' ""
        printf '#%-56s#\n' "   WARNING: AFFECTED FIRMWARE DETECTED"
        printf '#%-56s#\n' "   FIRMWARE UPDATE REQUIRED IMMEDIATELY"
        printf '#%-56s#\n' ""
        printf '#%.0s' {1..58}; echo
        printf "${RESET}"
        echo

        while IFS='|' read -r node model serial fw family; do
            [[ "${node}" == "BAD_FOUND" ]] && continue
            printf "${RED}  -> %s | %s | SN:%s | FW:%s | %s${RESET}\n" \
                "${node}" "${model}" "${serial}" "${fw}" "${family}"
        done <<< "${RESULT#BAD_FOUND$'\n'}"

        echo
        printf "${YELLOW}This firmware version is known to cause drives to enter an unrecoverable\n"
        echo "panic state. Update to the latest firmware as soon as possible."
        echo "See: https://www.micron.com/products/storage/ssd/micron-ssd-firmware"
        printf "${RESET}\n"

        # Collect distinct bad firmware versions found, prompt to download each once
        declare -A downloaded_bin
        local distinct_fw
        distinct_fw=$(echo "${RESULT#BAD_FOUND$'\n'}" | awk -F'|' '{print $4}' | sort -u)

        echo
        for fw in ${distinct_fw}; do
            url="${FW_URL[${fw}]:-}"
            bin_name="${FW_BIN[${fw}]:-}"
            target="${TARGET_FW[${fw}]:-}"

            if [[ -z "${url}" ]]; then
                echo "No known download URL for firmware ${fw}; skipping auto-download."
                continue
            fi

            zip_name="$(basename "${url}")"

            read -r -p "Download firmware ${fw} -> ${target} (${zip_name})? [y/N] " ans
            if [[ "${ans}" =~ ^[Yy]$ ]]; then
                echo "Downloading ${url} ..."
                if curl -fL -o "${zip_name}" "${url}"; then
                    echo "Extracting ${zip_name} ..."
                    if command -v unzip >/dev/null 2>&1; then
                        unzip -o "${zip_name}" -d "./${fw}_extracted" >/dev/null
                        found_bin=$(find "./${fw}_extracted" -iname "${bin_name}" -print -quit)
                        if [[ -n "${found_bin}" ]]; then
                            cp "${found_bin}" "./${bin_name}"
                            downloaded_bin["${fw}"]="./${bin_name}"
                            echo "Ready: ./${bin_name}"
                        else
                            echo "Warning: expected file ${bin_name} not found inside ${zip_name}." \
                                 "Check ./${fw}_extracted manually." >&2
                        fi
                    else
                        echo "Warning: 'unzip' not installed. Install it and extract ${zip_name} manually." >&2
                    fi
                else
                    echo "Warning: download failed for ${url}. Obtain ${bin_name} from your Micron contact instead." >&2
                fi
            fi
        done

        echo
        printf "${YELLOW}========================================================${RESET}\n"
        printf "${YELLOW} REMEDIATION COMMANDS${RESET}\n"
        printf "${YELLOW}========================================================${RESET}\n"

        while IFS='|' read -r node model serial fw family; do
            [[ "${node}" == "BAD_FOUND" ]] && continue

            target_fw="${TARGET_FW[${fw}]:-UNKNOWN}"
            fw_file="${downloaded_bin[${fw}]:-${FW_BIN[${fw}]:-UNKNOWN_FIRMWARE_FILE}}"
            fw_url="${FW_URL[${fw}]:-}"

            echo
            echo "# ${node}  (${model}, SN:${serial}, current FW:${fw} -> target FW:${target_fw})"
            if [[ "${fw_file}" != ./* ]]; then
                echo "# Obtain ${fw_file} from your Micron contact, or download:"
                echo "#   ${fw_url}"
            fi
            echo
            echo "sudo nvme fw-download ${node} -f ${fw_file}"
            echo "sudo nvme fw-commit ${node} -s 2 -a 3"
            echo "sudo nvme id-ctrl ${node} | grep fr"
        done <<< "${RESULT#BAD_FOUND$'\n'}"

        echo
        echo "# If fw-download fails with an Internal Error (0x4006), the drive may"
        echo "# be stuck in the panic precursor state. As a last resort (THIS ERASES"
        echo "# ALL DATA ON THE DRIVE), you can attempt the following on the affected"
        echo "# device(s) listed above:"
        echo "#   sudo nvme sanitize <device>"
        echo "#   sudo nvme sanitize-log <device>     # poll until complete"
        echo "#   then retry the fw-download/fw-commit commands above"

        printf "${YELLOW}========================================================${RESET}\n"
    else
        printf "${GREEN}No affected firmware versions detected.${RESET}\n"
    fi

    return ${found_bad}
}

main() {
    printf "${CYAN}"
    echo "========================================================"
    echo " Micron NVMe Firmware Check"
    echo " by Red Barn HPC | https://redbarnhpc.com"
    echo " v${SCRIPT_VERSION} | Released ${SCRIPT_RELEASE_DATE}"
    echo "========================================================"
    printf "${RESET}\n"

    install_nvme_cli
    scan_devices
}

main "$@"

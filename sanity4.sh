#!/bin/bash
################
# Service Monitoring Script - Improved Version
# $Rev::          $: Revision of last commit
# $Author::       $: Author of last commit
# $Date::         $: 2025-04-21
#
# Monitors: postgresql-15, nginx, httpd, mysql, sshd, dataiku-healthcheck
################
# ============================= CONFIGURACIÓN =============================
set -o errexit
set -o nounset
# set -o xtrace     # Descomentar solo para debug
SCRIPT_DIR="$(dirname "$0")"
LOG_FILE="/dataiku/app_scripts/dataiku_health/health02/health02.log"
EMAIL_STATE_FILE="/dataiku/app_scripts/dataiku_health/health02/.last_email"
CONFIG_FILE="${SCRIPT_DIR}/health02.cfg"
# ============================= FUNCIONES =============================
log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${level}: ${message}" | tee -a "$LOG_FILE"
}
send_email() {
    local subject="$1"
    local body="$2"
    {
        echo "To: ${MAILTO}"
        [ -n "${CC_LIST:-}" ] && echo "Cc: ${CC_LIST}"
        echo "From: ${MAILFROM:-${FID_USER}@${HOST_NAME}}"
        echo "Subject: ${subject}"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=utf-8"
        echo ""
        echo "$body"
    } | /usr/sbin/sendmail -t >> "${SCRIPT_DIR}/mailx_output.log" 2>> "${SCRIPT_DIR}/mailx_error.log"
    
    return $?
}
# ============================= VALIDACIONES INICIALES =============================
if [ ! -f "$CONFIG_FILE" ]; then
    log_message "ERROR" "Configuration file ${CONFIG_FILE} not found"
    exit 1
fi
. "$CONFIG_FILE"
# Variables obligatorias
: "${MAILTO:?MAILTO is not set in config file}"
: "${SUBJECT:?SUBJECT is not set in config file}"
HOST_NAME=$(hostname -f)
NOW=$(date '+%Y-%m-%d %H:%M:%S')
# Determinar entorno
ENVIRONMENT=""
for env in DEV UAT PERF PROD COB; do
    if [[ " ${NODES_ENV[$env]:-} " == *" $HOST_NAME "* ]]; then
        ENVIRONMENT="$env"
        break
    fi
done
if [ -z "$ENVIRONMENT" ]; then
    log_message "ERROR" "Could not determine ENVIRONMENT for host $HOST_NAME"
    exit 1
fi
FID_USER="${FID_USERS[$ENVIRONMENT]:-}"
if [ -z "$FID_USER" ]; then
    log_message "ERROR" "FID_USER not defined for ENVIRONMENT=$ENVIRONMENT"
    exit 1
fi
# ============================= SERVICIOS A MONITOREAR =============================
SERVICES=(
    postgresql-15
    nginx
    httpd
    mysql
    sshd
    dataiku-healthcheck
)
# ============================= EJECUCIÓN =============================
log_message "INFO" "Starting service monitoring on ${HOST_NAME} (${ENVIRONMENT})"
REPORT="Service Status Report"
REPORT+="\n================================"
REPORT+="\nHostname     : ${HOST_NAME}"
REPORT+="\nEnvironment  : ${ENVIRONMENT}"
REPORT+="\nDate         : ${NOW}"
REPORT+="\n\n"
REPORT+="Process Name          Status          Notes"
REPORT+="\n--------------------------------------------------\n"
ALL_SERVICES_UP=true
FAILED_SERVICES=()
for service in "${SERVICES[@]}"; do
    status_output=$(systemctl is-active "$service" 2>/dev/null)
    exit_code=$?
    case "$status_output" in
        "active")
            status="UP"
            notes=""
            ;;
        "inactive"|"failed"|"unknown")
            if systemctl is-failed "$service" &>/dev/null; then
                status="FAILED"
                notes="(failed)"
            else
                status="DOWN"
                notes="(inactive)"
            fi
            ALL_SERVICES_UP=false
            FAILED_SERVICES+=("$service")
            ;;
        *)
            status="UNKNOWN"
            notes="(exit code: $exit_code)"
            ALL_SERVICES_UP=false
            FAILED_SERVICES+=("$service")
            ;;
    esac
    # Alinear columnas
    printf -v line "%-20s %-15s %s" "$service" "$status" "$notes"
    REPORT+="${line}\n"
done
# ============================= DECISIÓN DE ENVÍO =============================
if [ "$ALL_SERVICES_UP" = true ]; then
    log_message "INFO" "All services are UP. No email sent."
    exit 0
fi
# Hay servicios caídos → evaluar throttling de emails
SEND_EMAIL=true
EMAIL_INTERVAL_SEC=$((15 * 60))  # 15 minutos (ajusta según necesites)
if [ -f "$EMAIL_STATE_FILE" ]; then
    LAST_EMAIL=$(cat "$EMAIL_STATE_FILE" 2>/dev/null || echo 0)
    ELAPSED=$(( $(date +%s) - LAST_EMAIL ))
    
    if [ "$ELAPSED" -lt "$EMAIL_INTERVAL_SEC" ]; then
        SEND_EMAIL=false
        log_message "INFO" "Services are down but email suppressed (last email sent ${ELAPSED}s ago)"
    fi
fi
if [ "$SEND_EMAIL" = true ]; then
    SUBJECT_LINE="${SUBJECT} <<FAILURE>> ${HOST_NAME} - ${ENVIRONMENT}"
    
    EMAIL_BODY="${REPORT}"
    EMAIL_BODY+="\n\nALERT: ${#FAILED_SERVICES[@]} service(s) are not running properly.\n"
    EMAIL_BODY+="Failed services: ${FAILED_SERVICES[*]}\n"
    if send_email "$SUBJECT_LINE" "$EMAIL_BODY"; then
        log_message "INFO" "Alert email sent successfully"
        date +%s > "$EMAIL_STATE_FILE"
    else
        log_message "ERROR" "Failed to send email. Check mailx_error.log"
    fi
fi
exit 0

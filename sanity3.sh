#!/bin/bash
################
# $Rev::          $: Revision of last commit
# $Author::       $: Author of last commit
# $Date::         $: Date of last commit   Orig: 01-dic-2025
#
# Comments: Validate the status of services.
################
set -x

log_message() {
    local level="$1"
    local message="$2"
    local log_file="/dataiku/app_scripts/dataiku_health/health02/health02.log"
    echo "$level: $message at $(date)" >> "$log_file"
}

# Invocar variables
if [ -f "$(dirname "$0")/health02.cfg" ]; then
    . "$(dirname "$0")/health02.cfg"
else
    log_message "ERROR" "Configuration file health02.cfg not found"
    exit 1
fi

# Obtener el hostname
HOST_NAME=$(hostname)

# Determinar ENV
ENVIRONMENT=""
for env in DEV UAT PERF PROD COB; do
    NODE_LIST="${NODES_ENV[$env]}"
    if echo "$NODE_LIST" | grep -qw "$HOST_NAME"; then
        ENVIRONMENT="$env"
        break
    fi
done

if [ -z "$ENVIRONMENT" ]; then
    log_message "ERROR" "Could not determine ENVIRONMENT for host $HOST_NAME"
    exit 1
fi

# Determinar FID
FID_USER="${FID_USERS[$ENVIRONMENT]}"
if [ -z "$FID_USER" ]; then
    log_message "ERROR" "FID_USER not defined for ENVIRONMENT=$ENVIRONMENT"
    exit 1
fi

# Array de servicios
PROCESS_NAME=(
    postgresql-15
    nginx
    httpd
    mysql
    sshd
    dataiku-healthcheck
)

get_gct_checkout() {
    local text_report="Service status report:\n\n"
    text_report+="Process Name          Status\n"
    text_report+="-------------------------------------\n"

    local ALL_UP=true
    local any_down=false
    
    for gct_proc in "${PROCESS_NAME[@]}"; do
        service="$gct_proc"
        gct_process_status=$(systemctl is-active "$service" 2>/dev/null)
        
        if [ "$gct_process_status" = "active" ]; then
            status="UP"
        else
            systemctl list-units --type=service --state=failed | grep -q "${gct_proc}" 2>/dev/null
            if [ $? -eq 0 ]; then
                status="EXITED"
            else
                status="DOWN"
            fi
            ALL_UP=false
            any_down=true
        fi

        text_report+=$(printf "%-20s %s\n" "$gct_proc" "$status")
    done

    if [ "$any_down" = false ]; then
        text_report="All services are UP."
    fi

    echo -e "$text_report"
}

# Capturar la salida de la tabla
TABLE=$(get_gct_checkout)

# Verificar todos los servicios UP
if [ "$ALL_UP" = "true" ]; then
    log_message "INFO" "All services are UP"
    exit 0
else
    EMAIL_STATE_FILE="/dataiku/app_scripts/dataiku_health/health02/.last_email"
    EMAIL_INTERVAL_SEC=$((1 * 60))

    now_ts=$(date +%s)
    send_email=true

    if [ -f "$EMAIL_STATE_FILE" ]; then
        last_ts=$(cat "$EMAIL_STATE_FILE" 2>/dev/null || echo 0)
        diff=$((now_ts - last_ts))
        if [ "$diff" -lt "$EMAIL_INTERVAL_SEC" ]; then
            send_email=false
            log_message "INFO" "Tareas fallaron pero se omite email (último hace ${diff}s). Intervalo: ${EMAIL_INTERVAL_SEC}s"
        fi
    fi

    if $send_email; then
        if [ -z "${MAILTO}" ]; then
            log_message "ERROR" "MAILTO is empty, cannot send email"
            exit 1
        fi

        if [ -z "${MAILFROM}" ]; then
            MAILFROM="${FID_USER}@${HOST_NAME}"
            log_message "WARNING" "MAILFROM not set in cfg, using FID_USER: ${MAILFROM}"
        else
            log_message "INFO" "MAILFROM loaded from cfg: ${MAILFROM}"
        fi

        CC_HEADER=""
        if [ -n "${CC_LIST}" ]; then
            CC_HEADER="Cc: ${CC_LIST}"
        fi

        log_message "INFO" "Sending email with service status report"
        
        # Crear correo en texto plano
        {
            echo "To: ${MAILTO}"
            echo "${CC_HEADER}"
            echo "From: ${MAILFROM}"
            echo "Subject: ${SUBJECT} ${HOST_NAME}"
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/plain; charset=utf-8"
            echo ""
            echo -e "$TABLE"  # Enviar la tabla como texto plano
        } | /usr/sbin/sendmail -t -v >> /dataiku/app_scripts/dataiku_health/health02/mailx_output.log 2>> /dataiku/app_scripts/dataiku_health/health02/mailx_error.log

        status=$?
        if [ $status -ne 0 ]; then
            log_message "ERROR" "Could not send failure email! Check mailx_error.log for details"
        else
            log_message "INFO" "Email sent successfully"
            echo "$now_ts" > "$EMAIL_STATE_FILE"
        fi
    fi
fi
exit 0

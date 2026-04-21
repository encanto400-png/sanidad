#!/bin/bash
################
# Service Monitoring Script
################
# 1. Configuración de rutas (Asegúrate que coincidan con tu servidor)
SCRIPT_DIR="/dataiku/app_scripts/dataiku_health/health02"
LOG_FILE="$SCRIPT_DIR/health02.log"
EMAIL_STATE_FILE="$SCRIPT_DIR/.last_email"
CONFIG_FILE="$SCRIPT_DIR/health02.cfg"
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1: $2" >> "$LOG_FILE"
}
# 2. Cargar archivo de configuración
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    log_message "ERROR" "Configuration file not found at $CONFIG_FILE"
    exit 1
fi
# 3. Identificar Host y Entorno
HOST_NAME=$(hostname)
ENVIRONMENT=""
for env in "${!NODES_ENV[@]}"; do
    if echo "${NODES_ENV[$env]}" | grep -qw "$HOST_NAME"; then
        ENVIRONMENT="$env"
        break
    fi
done
if [ -z "$ENVIRONMENT" ]; then
    log_message "ERROR" "No ENVIRONMENT found for $HOST_NAME"
    exit 1
fi
FID_USER="${FID_USERS[$ENVIRONMENT]}"
# 4. Monitoreo de Servicios
PROCESS_NAME=(postgresql-15 nginx dataiku-healthcheck)
ANY_DOWN=false
TABLE_CONTENT=""
for service in "${PROCESS_NAME[@]}"; do
    # Validación mejorada de Systemd
    if systemctl is-active --quiet "$service"; then
        STATUS="UP"
    else
        if systemctl is-failed --quiet "$service"; then
            STATUS="FAILED/EXITED"
        else
            STATUS="DOWN"
        fi
        ANY_DOWN=true
    fi
    # Formatear fila de la tabla
    printf -v ROW "%-20s %-15s\n" "$service" "$STATUS"
    TABLE_CONTENT+="$ROW"
done
# 5. Lógica de envío de correo
if [ "$ANY_DOWN" = "false" ]; then
    log_message "INFO" "All services UP on $HOST_NAME. No email needed."
    exit 0
fi
# Control de frecuencia (Intervalo de 1 minuto según tu script original)
NOW_TS=$(date +%s)
LAST_TS=$(cat "$EMAIL_STATE_FILE" 2>/dev/null || echo 0)
DIFF=$((NOW_TS - LAST_TS))
if [ "$DIFF" -lt 60 ]; then
    log_message "INFO" "Email suppressed. Last one was ${DIFF}s ago."
    exit 0
fi
# 6. Construcción del Correo Profesional
# Usamos las variables exactas de tu .cfg: MAILTO, MAILFROM, SUBJECT, CC_LIST
FINAL_SUBJECT="${SUBJECT} ${HOST_NAME}"
[ -z "$MAILFROM" ] && MAILFROM="${FID_USER}@$(hostname -f)"
{
    echo "To: ${MAILTO}"
    [ -z "${CC_LIST}" ] || echo "Cc: ${CC_LIST}"
    echo "From: ${MAILFROM}"
    echo "Subject: ${FINAL_SUBJECT}"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=utf-8"
    echo ""
    echo "Service status report for host: ${HOST_NAME} (${ENVIRONMENT})"
    echo "Date: $(date)"
    echo "------------------------------------------------------------"
    echo -e "Process Name         Status"
    echo "------------------------------------------------------------"
    echo -e "$TABLE_CONTENT"
    echo "------------------------------------------------------------"
    echo "Action required: Please check the services on the server."
} | /usr/sbin/sendmail -t
if [ $? -eq 0 ]; then
    log_message "INFO" "Failure email sent successfully."
    echo "$NOW_TS" > "$EMAIL_STATE_FILE"
else
    log_message "ERROR" "Failed to send email via sendmail."
fi

#!/bin/bash
###############################################################################
# Script de Monitoreo de Servicios - Versión Corregida
# Valida por Proceso (pgrep) y por Systemd para evitar falsos negativos.
###############################################################################
# 1. Rutas y Configuración
SCRIPT_DIR="/dataiku/app_scripts/dataiku_health/health02"
LOG_FILE="$SCRIPT_DIR/health02.log"
EMAIL_STATE_FILE="$SCRIPT_DIR/.last_email"
CONFIG_FILE="$SCRIPT_DIR/health02.cfg"
log_message() {
    local LEVEL="$1"
    local MSG="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${LEVEL}: ${MSG}" >> "$LOG_FILE"
}
# 2. Carga de Configuración (Variables del .cfg)
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    log_message "ERROR" "No se encontró el archivo de configuración: $CONFIG_FILE"
    exit 1
fi
# 3. Identificación de Host y Entorno
HOST_NAME=$(hostname)
ENVIRONMENT=""
# Iterar sobre el array de nodos definido en el .cfg
for env in "${!NODES_ENV[@]}"; do
    if echo "${NODES_ENV[$env]}" | grep -qw "$HOST_NAME"; then
        ENVIRONMENT="$env"
        break
    fi
done
if [ -z "$ENVIRONMENT" ]; then
    log_message "ERROR" "No se pudo determinar el entorno (DEV/UAT/PROD) para el host $HOST_NAME"
    exit 1
fi
# Obtener usuario FID según el entorno
FID_USER="${FID_USERS[$ENVIRONMENT]}"
# 4. Monitoreo de Servicios
# Lista de procesos a validar
SERVICES=(
    postgresql-15
    nginx
    httpd
    mysql
    sshd
    dataiku-healthcheck
)
ANY_DOWN=false
TABLE_CONTENT=""
for svc in "${SERVICES[@]}"; do
    # LÓGICA DE VALIDACIÓN:
    # Primero revisamos si el proceso existe en memoria (evita el error de 'inactive' en nginx)
    if pgrep -f "$svc" > /dev/null; then
        STATUS="UP"
    # Segundo, por si es un servicio de sistema que no muestra proceso directo
    elif systemctl is-active --quiet "$svc" 2>/dev/null; then
        STATUS="UP"
    else
        # Si no hay proceso ni está activo en systemctl, verificamos si falló o está apagado
        if systemctl is-failed --quiet "$svc" 2>/dev/null; then
            STATUS="EXITED"
        else
            STATUS="DOWN"
        fi
        ANY_DOWN=true
    fi
    # Formatear cada línea de la tabla (alineación de 25 caracteres para el nombre)
    printf -v ROW "%-25s %-10s\n" "$svc" "$STATUS"
    TABLE_CONTENT+="$ROW"
done
# 5. Lógica de salida y envío de Correo
if [ "$ANY_DOWN" = "false" ]; then
    log_message "INFO" "Todos los servicios están UP en $HOST_NAME. Fin del script."
    exit 0
fi
# Control de frecuencia de correos (Throttling) - 1 Minuto
NOW_TS=$(date +%s)
LAST_TS=$(cat "$EMAIL_STATE_FILE" 2>/dev/null || echo 0)
DIFF=$((NOW_TS - LAST_TS))
if [ "$DIFF" -lt 60 ]; then
    log_message "INFO" "Falla detectada pero correo omitido (último enviado hace ${DIFF}s)."
    exit 0
fi
# 6. Construcción del cuerpo del Correo en Texto Plano
FINAL_SUBJECT="${SUBJECT} ${HOST_NAME} (${ENVIRONMENT})"
[ -z "${MAILFROM}" ] && MAILFROM="${FID_USER}@$(hostname -f)"
# Generar el bloque de correo
{
    echo "To: ${MAILTO}"
    [ -n "${CC_LIST}" ] && echo "Cc: ${CC_LIST}"
    echo "From: ${MAILFROM}"
    echo "Subject: ${FINAL_SUBJECT}"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=utf-8"
    echo ""
    echo "SERVICE STATUS REPORT"
    echo "========================================"
    echo "Host:        ${HOST_NAME}"
    echo "Environment: ${ENVIRONMENT}"
    echo "Date:        $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo ""
    printf "%-25s %-10s\n" "PROCESS NAME" "STATUS"
    echo "----------------------------------------"
    echo -e "$TABLE_CONTENT"
    echo "----------------------------------------"
    echo ""
    echo "Action required: Please log in to the server and verify the services."
    echo "This is an automated alert from Dataiku HealthCheck."
} | /usr/sbin/sendmail -t
# 7. Finalización
if [ $? -eq 0 ]; then
    log_message "INFO" "Correo de alerta enviado exitosamente por fallas en servicios."
    echo "$NOW_TS" > "$EMAIL_STATE_FILE"
else
    log_message "ERROR" "Error al intentar enviar el correo mediante sendmail."
fi
exit 0

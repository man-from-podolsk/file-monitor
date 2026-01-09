#!/bin/bash
# === ПРОВЕРКИ СРАЗУ ===
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    logger -t "file-monitor" "Error: Bash version < 4"
    exit 1
fi
# === Значения по умолчанию ===
CONFIG_FILE="/etc/file-monitor.conf"
CACHE_DIR="/var/cache/file-monitor"
LOG_FILE="/var/log/file-monitor/file-monitor.log"
AUDIT_RULE_FILE="/etc/audit/rules.d/file-monitor.rules"
INTERVAL=60
AUDIT_KEY="file-monitor"
enable_diff="true"
max_file_size_kb=1024
declare -a PATHS=()
# --------------------------------------------------------------------------------------------------
# === ФУНКЦИИ ===
# --------------------------------------------------------------------------------------------------
# --- Загрузка конфигурации с валидацией ---
load_config() {
    local tmp_cache_dir="$CACHE_DIR"
    local tmp_log_file="$LOG_FILE"
    local tmp_interval="$INTERVAL"
    local tmp_audit_key="$AUDIT_KEY"
    local tmp_enable_diff="$enable_diff"
    local tmp_max_file_size_kb="$max_file_size_kb"
    local -a tmp_paths=()
    if [ -f "$CONFIG_FILE" ]; then
        while IFS='=' read -r key raw_value; do
            key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            raw_value=$(echo "$raw_value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            case "$key" in
                cache_dir)
                    tmp_cache_dir="$raw_value"
                    ;;
                log_file)
                    tmp_log_file="$raw_value"
                    ;;
                interval)
                    if ! [[ "$raw_value" =~ ^[0-9]+$ ]] || [ "$raw_value" -eq 0 ]; then
                        logger -t "file-monitor" "Invalid interval='$raw_value' (must be positive integer)"
                        return 1
                    fi
                    tmp_interval="$raw_value"
                    ;;
                audit_key)
                    if [[ -z "$raw_value" || "$raw_value" =~ [^a-zA-Z0-9_-] ]]; then
                        logger -t "file-monitor" "Invalid audit_key='$raw_value' (alphanumeric, '-', '_' only)"
                        return 1
                    fi
                    tmp_audit_key="$raw_value"
                    ;;
                enable_diff)
                    if [[ "$raw_value" != "true" && "$raw_value" != "false" ]]; then
                        logger -t "file-monitor" "Invalid enable_diff='$raw_value' (must be 'true' or 'false')"
                        return 1
                    fi
                    tmp_enable_diff="$raw_value"
                    ;;
                max_file_size_kb)
                    if ! [[ "$raw_value" =~ ^[0-9]+$ ]]; then
                        logger -t "file-monitor" "Invalid max_file_size_kb='$raw_value' (must be non-negative integer)"
                        return 1
                    fi
                    tmp_max_file_size_kb="$raw_value"
                    ;;
                path)
                    if [ -z "$raw_value" ]; then
                        logger -t "file-monitor" "Empty path ignored"
                        continue
                    fi
                    tmp_paths+=("$raw_value")
                    ;;
                *)
                    logger -t "file-monitor" "Warning: unknown config key '$key'"
                    ;;
            esac
        done < <(grep -v '^[[:space:]]*#' "$CONFIG_FILE")
    else
        logger -t "file-monitor" "Config not found: $CONFIG_FILE. Using defaults."
        tmp_paths=(
            "/etc/fstab"
        )
    fi
    # Применяем только если всё прошло валидацию
    CACHE_DIR="$tmp_cache_dir"
    LOG_FILE="$tmp_log_file"
    INTERVAL="$tmp_interval"
    AUDIT_KEY="$tmp_audit_key"
    enable_diff="$tmp_enable_diff"
    max_file_size_kb="$tmp_max_file_size_kb"
    PATHS=("${tmp_paths[@]}")
    # Гарантируем существование путей
    mkdir -p "$(dirname "$LOG_FILE")" "$CACHE_DIR" 2>/dev/null
    if ! touch "$LOG_FILE" &>/dev/null; then
        logger -t "file-monitor" "Error: Cannot create log file: $LOG_FILE"
        return 1
    fi
    chmod 644 "$LOG_FILE" 2>/dev/null
    # УСПЕХ: даже если конфига нет — это нормально
    return 0
}

# --- Создание audit правил ---
create_audit_rules() {
    local temp_rules=""
    local -a expanded_paths=()
    PATHS_TO_MONITOR=()
    for path in "${PATHS[@]}"; do
        eval "expanded_paths=($path)" 2>/dev/null || continue
        for item in "${expanded_paths[@]}"; do
            [ ! -e "$item" ] && continue
            if [ -d "$item" ]; then
                while IFS= read -r -d '' file; do
                    if [[ "$file" =~ \.swp$|~$|\.tmp$|\.bak$|\.bkp$|\.backup$|\.old$|\.rpmnew$|\.rpmsave$ ]] || \
                       [[ "$(basename "$file")" =~ ^[Rr][Ee][Aa][Dd][Mm][Ee]$ ]]; then
                        continue
                    fi
                    local size_kb=$(( $(stat -c%s "$file" 2>/dev/null || echo 0) / 1024 ))
                    if [ "$max_file_size_kb" -gt 0 ] && [ "$size_kb" -gt "$max_file_size_kb" ]; then
                        continue
                    fi
                    PATHS_TO_MONITOR+=("$file")
                done < <(find "$item" -type f -print0)
            elif [ -f "$item" ]; then
                local size_kb=$(( $(stat -c%s "$item" 2>/dev/null || echo 0) / 1024 ))
                if [ "$max_file_size_kb" -gt 0 ] && [ "$size_kb" -gt "$max_file_size_kb" ]; then
                    continue
                fi
                PATHS_TO_MONITOR+=("$item")
            fi
        done
    done
    readarray -t PATHS_TO_MONITOR < <(printf '%s\n' "${PATHS_TO_MONITOR[@]}" | sort -u)
    if [ ${#PATHS_TO_MONITOR[@]} -eq 0 ]; then
        logger -t "file-monitor" "Error: No valid paths found to monitor."
        return 1
    fi
    {
        echo "# WARNING: This file is auto-generated. Manual changes will be lost."
        echo "# Auto-generated audit rules for file integrity monitoring"
        echo "# Generated at $(date)"
        echo "# Monitored files: ${#PATHS_TO_MONITOR[@]}"
        echo "#"
        printf '%s\n' "${PATHS_TO_MONITOR[@]}" | sed "s|.*|-a always,exit -F arch=b64 -F path=& -F perm=wa -k $AUDIT_KEY|"
    } > "$AUDIT_RULE_FILE"
    chmod 644 "$AUDIT_RULE_FILE"
    if command -v augenrules >/dev/null 2>&1; then
        if ! augenrules --load >/dev/null 2>&1; then
            logger -t "file-monitor" "Error: Failed to load rules via augenrules."
            return 1
        fi
    else
        logger -t "file-monitor" "Error: augenrules not found."
        return 1
    fi
    return 0
}

# --- Логирование событий ---
log_event() {
    local event_type="$1"
    local file="$2"
    local detail="$3"
    local user="${4:-unknown}"
    {
        echo ' '
        printf '#%.0s' {1..100}; printf '\n'
        echo "$(date '+%d %b %Y %H:%M:%S') - File '$file' was $event_type by user '$user'. Details:"
        printf '#%.0s' {1..100}; printf '\n'
        echo -e "$detail"
        printf '\n'
    } >> "$LOG_FILE"
}

# --- Diff файлов ---
log_diff() {
    [ "$enable_diff" != "true" ] && return
    local FILE="$1"
    local CACHE_PATH="$CACHE_DIR/${FILE//\//_}"
    if [ ! -f "$CACHE_PATH.1" ] || [ ! -f "$CACHE_PATH.2" ]; then
        return
    fi
    local added=$(diff --new-line-format='%dn | %L' --old-line-format='' --unchanged-line-format='' "$CACHE_PATH.2" "$CACHE_PATH.1" )
    local deleted=$(diff --old-line-format='%dn | %L' --new-line-format='' --unchanged-line-format='' "$CACHE_PATH.2" "$CACHE_PATH.1" )
    [ -z "$added" -a -z "$deleted" ] && return
    local detail=""
    [ -n "$added" ] && detail+="Added lines:\n$added\n"
    [ -n "$deleted" ] && detail+="Deleted lines:\n$deleted\n"
    echo -e "$detail"
}

# --- Проверка метаданных ---
check_metadata_changes() {
    local FILE="$1"
    local CACHE_PATH="$CACHE_DIR/${FILE//\//_}"
    [ ! -f "${CACHE_PATH}.1" ] && return
    local cur=$(stat -c "%A:%U:%G" "$FILE" 2>/dev/null) || return
    local cache=$(stat -c "%A:%U:%G" "${CACHE_PATH}.1" 2>/dev/null) || return
    [[ "$cur" == "$cache" ]] && return
    IFS=':' read -r -a c <<< "$cur"
    IFS=':' read -r -a k <<< "$cache"
    local ch=()
    [ "${k[0]}" != "${c[0]}" ] && ch+=("permissions: ${k[0]} → ${c[0]}")
    [ "${k[1]}" != "${c[1]}" ] && ch+=("owner: ${k[1]} → ${c[1]}")
    [ "${k[2]}" != "${c[2]}" ] && ch+=("group: ${k[2]} → ${c[2]}")
    if [ ${#ch[@]} -gt 0 ]; then
        echo "Metadata changed:"
        printf '%s\n' "${ch[@]}"
    fi
}

# --- Кэширование файла ---
create_cache_for_file() {
    local FILE="$1"
    local USER="${2:-unknown}"
    local CACHE_PATH="$CACHE_DIR/${FILE//\//_}"
    [ ! -f "$FILE" ] && return 1
    local TMP=$(mktemp) || return 1
    if cp -p "$FILE" "$TMP"; then
        mv "$TMP" "${CACHE_PATH}.1"
        log_event "cached" "$FILE" "Initial cache created" "$USER"
        return 0
    else
        rm -f "$TMP"
        return 1
    fi
}

# --- Инициализация кэша ---
init_cache_for_monitored_files() {
    for FILE in "${PATHS_TO_MONITOR[@]}"; do
        [ ! -f "$FILE" ] && continue
        local CACHE_PATH="$CACHE_DIR/${FILE//\//_}"
        if [ ! -f "${CACHE_PATH}.1" ]; then
            create_cache_for_file "$FILE" "system"
        else
            local h1=$(sha256sum "$FILE" | cut -d' ' -f1)
            local h2=$(sha256sum "${CACHE_PATH}.1" | cut -d' ' -f1)
            if [ "$h1" != "$h2" ]; then
                mv -f "${CACHE_PATH}.1" "${CACHE_PATH}.2"
                local TMP=$(mktemp) || continue
                if cp -p "$FILE" "$TMP"; then
                    mv "$TMP" "${CACHE_PATH}.1"
                else
                    rm -f "$TMP"
                    continue
                fi
                local diff_out=$(log_diff "$FILE")
                if [ -n "$diff_out" ]; then
                    log_event "modified" "$FILE" "$diff_out" "system"
                else
                    log_event "modified" "$FILE" "File content changed before start" "system"
                fi
            fi
        fi
    done
}

# --- Парсинг событий auditd ---
parse_audit_events() {
    local LAST=$(date -d "$INTERVAL seconds ago" "+%H:%M:%S")
    local CURR=$(date "+%H:%M:%S")
    local EVENTS=$(ausearch -ts "$LAST" -te "$CURR" -k "$AUDIT_KEY" --format csv 2>/dev/null |
                   grep -E -v '(auditctl|null|~|unset)' | tail -n +2)
    [ -z "$EVENTS" ] && return

    declare -A file_events
    while IFS= read -r event; do
        # Парсим CSV: колонки - ID(5), USER(8), ACTION(11), FILE(13)
        local ID=$(echo "$event" | awk -F',' '{print $5}')
        local USER=$(echo "$event" | awk -F',' '{print $8}')
        local FILE=$(echo "$event" | awk -F',' '{print $13}')

        [ -z "$ID" ] || [ -z "$USER" ] || [ -z "$FILE" ] && continue

        # Проверяем, отслеживается ли файл 
        local is_monitored=false
        for mf in "${PATHS_TO_MONITOR[@]}"; do
            [[ "$mf" == "$FILE" ]] && is_monitored=true && break
        done
        [ "$is_monitored" = false ] && continue

        file_events["$FILE"]="${USER}:${ID}"
    done <<< "$EVENTS"

    for FILE in "${!file_events[@]}"; do
        IFS=':' read -r USER ID <<< "${file_events[$FILE]}"
        local CACHE_PATH="$CACHE_DIR/${FILE//\//_}"
        local detail=""
        local changed=false

        # Случай 1: Файл существует
        if [ -f "$FILE" ]; then
            if [ -f "${CACHE_PATH}.1" ]; then
                # Проверка метаданных
                local meta_out=$(check_metadata_changes "$FILE")
                if [ -n "$meta_out" ]; then
                    detail+="$meta_out\n"
                    changed=true
                fi

                # Проверка содержимого
                local h1=$(sha256sum "$FILE" | cut -d' ' -f1)
                local h2=$(sha256sum "${CACHE_PATH}.1" | cut -d' ' -f1)
                if [ "$h1" != "$h2" ]; then
                    mv -f "${CACHE_PATH}.1" "${CACHE_PATH}.2"
                    if cp -p "$FILE" "${CACHE_PATH}.1"; then
                        local diff_out=$(log_diff "$FILE")
                        if [ -n "$diff_out" ]; then
                            detail+="$diff_out"
                            changed=true
                        fi
                    fi
                fi

                # Обновление метаданных кеша
                if [ -n "$meta_out" ]; then
                    chmod --reference="$FILE" "${CACHE_PATH}.1" 2>/dev/null || true
                    chown --reference="$FILE" "${CACHE_PATH}.1" 2>/dev/null || true
                fi
            else
                # Новый файл в мониторинге
                create_cache_for_file "$FILE" "system"
                detail="Initial cache created"
                changed=true
            fi

        # Случай 2: Файл удалён
        elif [ ! -f "$FILE" ] && [ -f "${CACHE_PATH}.1" ] ; then
            local CMD=$(ausearch -a "$ID" -i 2>/dev/null | sed -n "s/.*proctitle=//p")
            [ -z "$CMD" ] && CMD="unknown command"

            detail="File DELETED by: $CMD (event ID: $ID)"
            log_event "DELETED" "$FILE" "$detail" "$USER"

            # Помечаем кеш как удалённый
            mv "${CACHE_PATH}.1" "${CACHE_PATH}.deleted"
            [ -f "${CACHE_PATH}.2" ] && rm -f "${CACHE_PATH}.2"
            continue
        fi

        # Логируем изменения только для существующих файлов
        if [ "$changed" = true ] && [ -f "$FILE" ]; then
            # Получаем команду, которая вызвала изменение
            local CMD=$(ausearch -a "$ID" -i 2>/dev/null | sed -n "s/.*proctitle=//p")
            [ -z "$CMD" ] && CMD="unknown command"

            # Формируем детали в правильном порядке
            local cmd_detail="Command triggered change: $CMD (event ID: $ID)\n"
            if [ -n "$detail" ]; then
                detail="$cmd_detail\n$detail"
            else
                detail="$cmd_detail"
            fi

            log_event "modified" "$FILE" "$detail" "$USER"
        fi
    done
}

# --------------------------------------------------------------------------------------------------
# === ОСНОВНОЕ ВЫПОЛНЕНИЕ ===
# --------------------------------------------------------------------------------------------------

# Загружаем конфиг
if ! load_config; then
    logger -t "file-monitor" "Failed to load initial configuration. Exiting."
    exit 1
fi
# Создаём правила и кэш
if ! create_audit_rules; then
    logger -t "file-monitor" "Failed to create audit rules. Exiting."
    exit 1
fi
init_cache_for_monitored_files
# Главный цикл
while true; do
    parse_audit_events
    sleep "$INTERVAL"
done

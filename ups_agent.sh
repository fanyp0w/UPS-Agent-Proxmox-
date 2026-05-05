#!/bin/bash
# =============================================================
# UPS Cluster Agent для Proxmox хоста
# /opt/ups-agent/ups_agent.sh
# =============================================================

CONFIG="/etc/ups-agent/cluster.conf"
LOGFILE="/var/log/ups-agent.log"
PIDFILE="/var/run/ups-agent.pid"
STATE_FILE="/var/run/ups-agent.state"
SHUTDOWN_FLAG="/var/run/ups-agent.shutdown"

[[ ! -f "$CONFIG" ]] && echo "Конфиг не найден: $CONFIG" && exit 1
source "$CONFIG"

# ─────────────────────── Логирование ────────────────────────────

log() {
    local level="$1"; shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" | tee -a "$LOGFILE"
}
log_info() { log "INFO " "$*"; }
log_warn() { log "WARN " "$*"; }
log_crit() { log "CRIT " "$*"; }

# ─────────────────────── Чтение ИБП ─────────────────────────────

read_ups() {
    local status bat runtime

    status=$(upsc "${UPS_NAME}@${UPS_HOST}" ups.status 2>/dev/null)
    bat=$(upsc "${UPS_NAME}@${UPS_HOST}" battery.charge 2>/dev/null)
    runtime=$(upsc "${UPS_NAME}@${UPS_HOST}" battery.runtime 2>/dev/null)

    [[ -z "$status" ]] && echo "error" && return 1

    local on_battery=0
    echo "$status" | grep -qE "OB|DISCHRG" && on_battery=1

    bat=${bat:-100}
    runtime=${runtime:-0}
    runtime=$(( runtime / 60 ))

    echo "${on_battery}|${bat}|${runtime}"
}

# ─────────────────────── Gossip сервер ──────────────────────────

gossip_server() {
    log_info "Gossip сервер запущен на порту $GOSSIP_PORT"
    while true; do
        local on_bat=0 bat_pct=100 runtime_min=0
        [[ -f "$STATE_FILE" ]] && IFS='|' read -r on_bat bat_pct runtime_min < "$STATE_FILE"

        local ts body response
        ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        body="{\"host\":\"${HOST_NAME}\",\"ip\":\"${HOST_IP}\",\"role\":\"${HOST_ROLE}\",\"priority\":${SHUTDOWN_PRIORITY},\"on_battery\":${on_bat},\"battery_pct\":${bat_pct},\"runtime_min\":${runtime_min},\"timestamp\":\"${ts}\"}"
        response="HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${#body}\r\nConnection: close\r\n\r\n${body}"

        echo -e "$response" | nc -l -p "$GOSSIP_PORT" -q 1 2>/dev/null
    done
}

# ─────────────────────── Опрос пира ─────────────────────────────

fetch_peer() {
    local peer="$1"
    local result
    result=$(curl -s --max-time 5 "http://${peer}/status" 2>/dev/null)
    [[ -z "$result" ]] && echo "unreachable" && return 1

    local on_bat host bat_pct
    on_bat=$(echo "$result"  | grep -oP '"on_battery":\K[^,}]+')
    bat_pct=$(echo "$result" | grep -oP '"battery_pct":\K[^,}]+')
    host=$(echo "$result"    | grep -oP '"host":"\K[^"]+')

    echo "${host}|${on_bat}|${bat_pct}"
}

# ─────────────────────── Кворум ─────────────────────────────────

evaluate_quorum() {
    local my_on_bat="$1"
    local my_bat_pct="$2"
    local my_runtime="$3"

    [[ "$my_on_bat" != "1" ]] && echo "online" && return

    # Критический заряд — немедленный shutdown
    if (( my_bat_pct <= CRITICAL_BATTERY )); then
        echo "critical:battery_${my_bat_pct}%"
        return
    fi

    # Критическое время — немедленный shutdown (приоритет над кворумом)
    if (( my_runtime <= CRITICAL_RUNTIME_MIN )); then
        echo "critical:runtime_${my_runtime}min"
        return
    fi

    local total=1 on_bat_count=1 unreachable=0
    local peer_count=0

    IFS=',' read -ra PEER_LIST <<< "$PEERS"
    for peer in "${PEER_LIST[@]}"; do
        [[ -z "$peer" ]] && continue
        (( peer_count++ ))
        local result
        result=$(fetch_peer "$peer")

        if [[ "$result" == "unreachable" ]]; then
            (( unreachable++ ))
            log_warn "Пир $peer недоступен"
        else
            (( total++ ))
            local peer_on_bat peer_host peer_bat
            peer_host=$(echo "$result"   | cut -d'|' -f1)
            peer_on_bat=$(echo "$result" | cut -d'|' -f2)
            peer_bat=$(echo "$result"    | cut -d'|' -f3)

            if [[ "$peer_on_bat" == "1" || "$peer_on_bat" == "true" ]]; then
                (( on_bat_count++ ))
                log_warn "Пир $peer_host тоже на батарее (${peer_bat}%)"
            else
                log_info "Пир $peer_host в сети (${peer_bat}%)"
            fi
        fi
    done

    log_info "Кворум: на батарее ${on_bat_count}/${total} | недоступно: ${unreachable}"

    # Все пиры недоступны — автономный shutdown
    if (( peer_count > 0 && unreachable == peer_count )); then
        echo "autonomous:все_пиры_недоступны"
        return
    fi

    case "$QUORUM_POLICY" in
        majority)
            (( on_bat_count * 2 > total )) \
                && echo "majority:${on_bat_count}/${total}" \
                || echo "waiting:${on_bat_count}/${total}" ;;
        all)
            (( on_bat_count == total )) \
                && echo "all:${on_bat_count}/${total}" \
                || echo "waiting:${on_bat_count}/${total}" ;;
        any)
            echo "any:на_батарее" ;;
        *)
            echo "waiting:неизвестная_политика" ;;
    esac
}

# ─────────────────────── Shutdown ───────────────────────────────

do_shutdown() {
    local reason="$1"
    [[ -f "$SHUTDOWN_FLAG" ]] && return
    touch "$SHUTDOWN_FLAG"

    log_crit "SHUTDOWN инициирован. Причина: $reason"

    if [[ -n "$PRE_SHUTDOWN_SCRIPT" && -x "$PRE_SHUTDOWN_SCRIPT" ]]; then
        log_info "Запуск pre-shutdown скрипта..."
        timeout 150 "$PRE_SHUTDOWN_SCRIPT" || log_warn "Pre-shutdown завершился с ошибкой"
    fi

    log_crit "Выполняю: $SHUTDOWN_COMMAND"
    $SHUTDOWN_COMMAND
}

# ─────────────────────── Главный цикл ───────────────────────────

main_loop() {
    local shutdown_at=0

    while true; do
        local ups_data
        ups_data=$(read_ups)

        if [[ "$ups_data" == "error" ]]; then
            log_warn "Не удалось прочитать статус ИБП"
            sleep "$POLL_INTERVAL"
            continue
        fi

        local on_bat bat_pct runtime_min
        IFS='|' read -r on_bat bat_pct runtime_min <<< "$ups_data"

        echo "${on_bat}|${bat_pct}|${runtime_min}" > "$STATE_FILE"

        if [[ "$on_bat" == "1" ]]; then
            log_warn "ИБП: НА БАТАРЕЕ | заряд=${bat_pct}% | осталось ~${runtime_min} мин"
        else
            log_info "ИБП: в сети | заряд=${bat_pct}%"
            if (( shutdown_at > 0 )); then
                log_info "Питание восстановлено — shutdown отменён"
                shutdown_at=0
                rm -f "$SHUTDOWN_FLAG"
            fi
        fi

        local verdict verdict_type
        verdict=$(evaluate_quorum "$on_bat" "$bat_pct" "$runtime_min")
        verdict_type="${verdict%%:*}"

        case "$verdict_type" in
            online)
                shutdown_at=0 ;;
            critical|autonomous)
                log_crit "Немедленный shutdown: $verdict"
                do_shutdown "$verdict" ;;
            majority|all|any)
                if (( shutdown_at == 0 )); then
                    shutdown_at=$(( $(date +%s) + SHUTDOWN_DELAY ))
                    log_warn "Кворум принят ($verdict) — shutdown через ${SHUTDOWN_DELAY} сек"
                else
                    local remaining=$(( shutdown_at - $(date +%s) ))
                    if (( remaining <= 0 )); then
                        log_crit "Обратный отсчёт истёк — выполняю shutdown"
                        do_shutdown "$verdict"
                    else
                        log_warn "Shutdown через ${remaining} сек (причина: $verdict)"
                    fi
                fi ;;
            waiting)
                log_info "Жду кворума: $verdict"
                shutdown_at=0 ;;
        esac

        sleep "$POLL_INTERVAL"
    done
}

# ─────────────────────── Точка входа ────────────────────────────

echo $$ > "$PIDFILE"
log_info "UPS Agent запускается | хост=${HOST_NAME} | ИБП=${UPS_NAME}@${UPS_HOST} | пиры=${PEERS}"

gossip_server &
GOSSIP_PID=$!

trap "log_info 'Завершение агента'; kill $GOSSIP_PID 2>/dev/null; rm -f $PIDFILE $STATE_FILE; exit 0" SIGTERM SIGINT

main_loop

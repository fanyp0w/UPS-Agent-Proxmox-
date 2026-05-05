#!/bin/bash
# /etc/ups-agent/pre-shutdown.sh
# Останавливает все VM и LXC перед выключением Proxmox хоста
# Основан на github.com/NUT-Proxmox скрипте, адаптирован под наш агент
# ─────────────────────────────────────────────────────────────────

LOGFILE="/var/log/ups-agent.log"

# ── Настройки ──
ACTION_DELAY=1          # сек между командами (защита от I/O burst)
SHUTDOWN_TIMEOUT=60     # сек ждём graceful shutdown
SYNC_AFTER_ACTION=true  # sync после каждого действия

# Действие по умолчанию для VM: shutdown | hibernate
DEFAULT_VM_ACTION="shutdown"

# Исключения для конкретных VM (VMID → действие)
# Пример: VM_ACTIONS[105]="hibernate"
declare -A VM_ACTIONS
# VM_ACTIONS[100]="hibernate"
# VM_ACTIONS[101]="shutdown"

# ─────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] PRE-SHUTDOWN: $*" | tee -a "$LOGFILE" | logger -t ups-agent; }

log "========================================="
log "Начинаем остановку гостей Proxmox"
log "========================================="

# ─────────────────── Останавливаем LXC ───────────────────────────

RUNNING_CTS=$(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}' | xargs -r)

if [[ -z "$RUNNING_CTS" ]]; then
    log "Запущенных LXC не найдено"
else
    log "Останавливаем LXC контейнеры: $RUNNING_CTS"
    for CTID in $RUNNING_CTS; do
        NAME=$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/{print $2}')
        log "  → LXC $CTID ($NAME) — shutdown"
        pct shutdown "$CTID" --timeout "$SHUTDOWN_TIMEOUT"
        $SYNC_AFTER_ACTION && sync
        sleep "$ACTION_DELAY"
    done
fi

# ─────────────────── Останавливаем QEMU VM ───────────────────────

RUNNING_VMS=$(qm list 2>/dev/null | awk '$3=="running" {print $1}' | xargs -r)

if [[ -z "$RUNNING_VMS" ]]; then
    log "Запущенных QEMU VM не найдено"
else
    log "Останавливаем QEMU VM: $RUNNING_VMS"
    for VMID in $RUNNING_VMS; do
        NAME=$(qm config "$VMID" 2>/dev/null | awk '/^name:/{print $2}')
        ACTION="${VM_ACTIONS[$VMID]:-$DEFAULT_VM_ACTION}"
        log "  → VM $VMID ($NAME) — $ACTION"

        if [[ "$ACTION" == "hibernate" ]]; then
            qm suspend "$VMID" --todisk 1
        else
            qm shutdown "$VMID" --skiplock 1 --timeout "$SHUTDOWN_TIMEOUT"
        fi

        $SYNC_AFTER_ACTION && sync
        sleep "$ACTION_DELAY"
    done
fi

# ─────────────────── Принудительная остановка оставшихся ─────────

log "Проверяем оставшихся гостей..."
sleep "$SHUTDOWN_TIMEOUT"

# LXC
STUCK_CTS=$(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}' | xargs -r)
for CTID in $STUCK_CTS; do
    log "  ! LXC $CTID не остановился — принудительно"
    pct stop "$CTID" --skiplock 1
    $SYNC_AFTER_ACTION && sync
    sleep "$ACTION_DELAY"
done

# VM
STUCK_VMS=$(qm list 2>/dev/null | awk '$3=="running" {print $1}' | xargs -r)
for VMID in $STUCK_VMS; do
    log "  ! VM $VMID не остановилась — принудительно"
    qm stop "$VMID" --skiplock 1
    $SYNC_AFTER_ACTION && sync
    sleep "$ACTION_DELAY"
done

# ─────────────────── Итог ────────────────────────────────────────

FINAL_VMS=$(qm list 2>/dev/null | awk '$3=="running" {print $1}' | xargs -r)
FINAL_CTS=$(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}' | xargs -r)

if [[ -z "$FINAL_VMS" && -z "$FINAL_CTS" ]]; then
    log "Все гости успешно остановлены"
else
    [[ -n "$FINAL_VMS" ]] && log "ВНИМАНИЕ: остались VM: $FINAL_VMS"
    [[ -n "$FINAL_CTS" ]] && log "ВНИМАНИЕ: остались LXC: $FINAL_CTS"
fi

log "Синхронизация дисков..."
sync

log "Pre-shutdown завершён"
log "========================================="

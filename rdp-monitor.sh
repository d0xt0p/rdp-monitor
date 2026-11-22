#!/bin/bash

# ============================================================
# RDP Monitor for Remmina
# ALT Linux / Bash 4.4+
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

umask 077
ALERT_FILE="${RDP_MONITOR_ALERT_FILE:-$SCRIPT_DIR/alert.mp3}"
VPN_INTERFACE="${RDP_MONITOR_VPN_INTERFACE:-tun0}"

PID_FILE="$SCRIPT_DIR/rdp-monitor.pid"
ALARM_PID_FILE="$SCRIPT_DIR/rdp-monitor.alarm.pid"
STATE_FILE="$SCRIPT_DIR/rdp-monitor.state"
SNOOZE_FILE="$SCRIPT_DIR/rdp-monitor.snooze"
LOCK_FILE="$SCRIPT_DIR/rdp-monitor.lock"
GUI_PID_FILE="$SCRIPT_DIR/rdp-monitor.gui.pid"
NETWORK_FILE="$SCRIPT_DIR/rdp-monitor.network"
NETWORK_LOCK_FILE="$SCRIPT_DIR/rdp-monitor.network.lock"
PROFILE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/remmina"

CHECK_INTERVAL=2
DISCONNECT_DELAY=5
SNOOZE_TIME=60

# ============================================================
# Запись состояния
# ============================================================

write_state() {
    local state="$1"
    local peer="$2"
    local event="$3"
    local alarm="$4"
    local snooze="$5"

    cat > "$STATE_FILE" <<EOF
STATE=$state
RDP_PEER=$peer
LAST_EVENT=$event
ALARM=$alarm
SNOOZE_UNTIL=$snooze
MONITOR_PID=$$
REMMINA_PID=$(get_remmina_pid)
UPDATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
}

# ============================================================
# Найти активное RDP-соединение Remmina
# ============================================================

get_rdp_peer() {
    ss -tnp 2>/dev/null |
        awk '
            $1 == "ESTAB" &&
            /remmina/ &&
            $5 ~ /:3389$/ {
                print $5
                exit
            }
        '
}

# ============================================================
# Найти PID Remmina
# ============================================================

get_remmina_pid() {
    ss -tnp 2>/dev/null |
        sed -n 's/.*users:(("\?remmina",pid=\([0-9][0-9]*\).*/\1/p' |
        head -1
}

# ============================================================
# Запустить тревогу
# ============================================================

alarm_loop() {

    PAPLAY_PID=""

    alarm_cleanup() {
        if [ -n "$PAPLAY_PID" ]; then
            if kill -0 "$PAPLAY_PID" 2>/dev/null; then
                kill -TERM "$PAPLAY_PID" 2>/dev/null
            fi
        fi
    }

    trap 'alarm_cleanup; exit 0' INT TERM

    while true
    do
        paplay "$ALERT_FILE" >/dev/null 2>&1 &
        PAPLAY_PID=$!

        wait "$PAPLAY_PID"

        PAPLAY_PID=""

        sleep 0.1
    done
}

start_alarm() {

    if [ ! -f "$ALARM_PID_FILE" ]; then

        (
            alarm_loop
        ) &

        echo $! > "$ALARM_PID_FILE"
        return
    fi

    OLD_PID=$(cat "$ALARM_PID_FILE" 2>/dev/null)

    if [ -n "$OLD_PID" ] &&
       kill -0 "$OLD_PID" 2>/dev/null
    then
        return
    fi

    rm -f "$ALARM_PID_FILE"

    (
        alarm_loop
    ) &

    echo $! > "$ALARM_PID_FILE"
}

# ============================================================
# Остановить тревогу
# ============================================================

stop_alarm() {

    if [ -f "$ALARM_PID_FILE" ]; then

        ALARM_PID=$(cat "$ALARM_PID_FILE" 2>/dev/null)

        if [ -n "$ALARM_PID" ] &&
           kill -0 "$ALARM_PID" 2>/dev/null
        then
            kill -TERM "$ALARM_PID" 2>/dev/null
        fi

        rm -f "$ALARM_PID_FILE"
    fi
}

# ============================================================
# Корректное завершение MONITOR
# ============================================================

cleanup() {

    stop_alarm

    rm -f "$PID_FILE"
    rm -f "$STATE_FILE"
    rm -f "$SNOOZE_FILE"
}

# ============================================================
# Основной монитор
# ============================================================

monitor() {

    exec 9>"$LOCK_FILE"

    if ! flock -n 9
    then
        exit 0
    fi

    # Только monitor получает эти traps.
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    echo $$ > "$PID_FILE"

    STATE="UNKNOWN"
    LOST_COUNT=0
    SNOOZE_UNTIL=0
    RDP_PEER=""

    echo "RDP monitor started"
    echo "Alert: $ALERT_FILE"
    echo "Check interval: ${CHECK_INTERVAL}s"
    echo "Disconnect delay: $DISCONNECT_DELAY checks"
    echo

    while true
    do

        CURRENT_PEER=$(get_rdp_peer)
        NOW=$(date +%s)

        # ----------------------------------------------------
        # Обработка команды SNOOZE
        # ----------------------------------------------------

        if [ -f "$SNOOZE_FILE" ]; then

            REQUESTED_SNOOZE=$(cat "$SNOOZE_FILE" 2>/dev/null)

            rm -f "$SNOOZE_FILE"

            if echo "$REQUESTED_SNOOZE" | grep -q '^[0-9][0-9]*$'
            then
                SNOOZE_UNTIL="$REQUESTED_SNOOZE"

                stop_alarm

                write_state \
                    "$STATE" \
                    "$RDP_PEER" \
                    "$(date '+%H:%M:%S') — звук отложен" \
                    "OFF" \
                    "$SNOOZE_UNTIL"
            fi
        fi

        # ----------------------------------------------------
        # Соединение есть
        # ----------------------------------------------------

        if [ -n "$CURRENT_PEER" ]
        then

            RDP_PEER="$CURRENT_PEER"

            # Если соединение восстановилось после DISCONNECTED
            if [ "$STATE" = "DISCONNECTED" ]
            then

                echo "$(date '+%H:%M:%S') [OK] RDP connection restored: $RDP_PEER"

                stop_alarm

                STATE="CONNECTED"
                LOST_COUNT=0
                SNOOZE_UNTIL=0

                write_state \
                    "CONNECTED" \
                    "$RDP_PEER" \
                    "$(date '+%H:%M:%S') — соединение восстановлено" \
                    "OFF" \
                    "0"

            # Первое обнаружение соединения
            elif [ "$STATE" != "CONNECTED" ]
            then

                echo "$(date '+%H:%M:%S') [OK] RDP connected: $RDP_PEER"

                STATE="CONNECTED"
                LOST_COUNT=0
                SNOOZE_UNTIL=0

                write_state \
                    "CONNECTED" \
                    "$RDP_PEER" \
                    "$(date '+%H:%M:%S') — соединение установлено" \
                    "OFF" \
                    "0"

            else

                LOST_COUNT=0

            fi

        # ----------------------------------------------------
        # Соединения нет
        # ----------------------------------------------------

        else

            if [ "$STATE" = "CONNECTED" ]
            then

                LOST_COUNT=$((LOST_COUNT + 1))

                echo "$(date '+%H:%M:%S') [CHECK] RDP lost $LOST_COUNT/$DISCONNECT_DELAY"

                if [ "$LOST_COUNT" -ge "$DISCONNECT_DELAY" ]
                then

                    STATE="DISCONNECTED"
                    LOST_COUNT=0

                    echo "$(date '+%H:%M:%S') [ALERT] RDP connection is DOWN!"

                    write_state \
                        "DISCONNECTED" \
                        "$RDP_PEER" \
                        "$(date '+%H:%M:%S') — соединение потеряно" \
                        "OFF" \
                        "$SNOOZE_UNTIL"

                    if [ "$NOW" -ge "$SNOOZE_UNTIL" ]
                    then

                        start_alarm

                        write_state \
                            "DISCONNECTED" \
                            "$RDP_PEER" \
                            "$(date '+%H:%M:%S') — тревога" \
                            "ON" \
                            "$SNOOZE_UNTIL"
                    fi
                fi

            elif [ "$STATE" = "DISCONNECTED" ]
            then

                # ------------------------------------------------
                # Проверка окончания snooze
                # ------------------------------------------------

                if [ "$NOW" -ge "$SNOOZE_UNTIL" ]
                then

                    if [ ! -f "$ALARM_PID_FILE" ]
                    then

                        echo "$(date '+%H:%M:%S') [ALERT] RDP still DOWN — alarm"

                        start_alarm

                        write_state \
                            "DISCONNECTED" \
                            "$RDP_PEER" \
                            "$(date '+%H:%M:%S') — тревога" \
                            "ON" \
                            "$SNOOZE_UNTIL"
                    fi

                else

                    # Snooze ещё действует.
                    stop_alarm

                    write_state \
                        "DISCONNECTED" \
                        "$RDP_PEER" \
                        "$(date '+%H:%M:%S') — звук отложен" \
                        "OFF" \
                        "$SNOOZE_UNTIL"
                fi

            fi
        fi

        sleep "$CHECK_INTERVAL"

    done
}

# ============================================================
# START
# ============================================================

start_monitor() {

    if [ -f "$PID_FILE" ]
    then

        PID=$(cat "$PID_FILE" 2>/dev/null)

        if [ -n "$PID" ] &&
           kill -0 "$PID" 2>/dev/null
        then
            echo "RDP monitor already running. PID: $PID"
            exit 0
        fi

        rm -f "$PID_FILE"
    fi

    nohup "$0" monitor >/dev/null 2>&1 &

    sleep 1

    if [ -f "$PID_FILE" ]
    then
        echo "RDP monitor started. PID: $(cat "$PID_FILE")"
    else
        echo "Failed to start RDP monitor."
        exit 1
    fi
}

# ============================================================
# STOP
# ============================================================

stop_monitor() {

    if [ ! -f "$PID_FILE" ]
    then

        echo "RDP monitor is not running."

        stop_alarm

        rm -f "$STATE_FILE"
        rm -f "$SNOOZE_FILE"

        exit 0
    fi

    PID=$(cat "$PID_FILE" 2>/dev/null)

    if [ -n "$PID" ] &&
       kill -0 "$PID" 2>/dev/null
    then

        kill -TERM "$PID" 2>/dev/null

        # Ждём завершения monitor.
        for i in 1 2 3 4 5
        do
            if ! kill -0 "$PID" 2>/dev/null
            then
                break
            fi

            sleep 1
        done

        # Если по какой-то причине не завершился.
        if kill -0 "$PID" 2>/dev/null
        then
            kill -KILL "$PID" 2>/dev/null
        fi

        stop_alarm

        rm -f "$PID_FILE"
        rm -f "$STATE_FILE"
        rm -f "$SNOOZE_FILE"

        echo "RDP monitor stopped. PID: $PID"

    else

        rm -f "$PID_FILE"
        stop_alarm
        rm -f "$STATE_FILE"
        rm -f "$SNOOZE_FILE"

        echo "RDP monitor process not found."
    fi
}

# ============================================================
# Проверка доступности сети (вызывается GUI асинхронно)
# ============================================================

probe_url() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -L -sS -o /dev/null --connect-timeout 3 --max-time 5 "$url" >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 5 --spider "$url" >/dev/null 2>&1
    else
        return 127
    fi
}

network_refresh() {
    local tunnel_status="DOWN"
    local tunnel_detail="$VPN_INTERFACE отсутствует"
    local internet_status="UNAVAILABLE"
    local internet_target="none"
    local tmp_file="${NETWORK_FILE}.tmp.$$"
    local link_info=""
    local ipv4_info=""

    # Не допускаем одновременных сетевых проверок.
    exec 8>"$NETWORK_LOCK_FILE"
    if ! flock -n 8; then
        exit 0
    fi


    # Состояние интерфейса VPN-туннеля.
    # Проверяем флаги UP и LOWER_UP, а также наличие IPv4-адреса.
    if command -v ip >/dev/null 2>&1; then
        link_info=$(ip -o link show dev "$VPN_INTERFACE" 2>/dev/null)
        ipv4_info=$(ip -o -4 addr show dev "$VPN_INTERFACE" 2>/dev/null)

        if [[ "$link_info" =~ \<[^[:space:]]*UP[^[:space:]]*LOWER_UP[^[:space:]]*\> ]] &&
           [ -n "$ipv4_info" ]; then
            tunnel_status="UP"
            tunnel_detail=$(printf '%s\n' "$ipv4_info" | awk '{print $4; exit}')
        elif [ -n "$link_info" ]; then
            tunnel_detail="интерфейс найден, но не активен или без IPv4"
        else
            tunnel_detail="интерфейс $VPN_INTERFACE не найден"
        fi
    else
        tunnel_detail="команда ip недоступна"
    fi

    if probe_url "https://www.cloudflare.com/"; then
        internet_status="AVAILABLE"
        internet_target="www.cloudflare.com"
    elif probe_url "https://ya.ru/"; then
        internet_status="AVAILABLE"
        internet_target="ya.ru"
    fi

    {
        printf 'TUNNEL_STATUS=%s\n' "$tunnel_status"
        printf 'TUNNEL_DETAIL=%s\n' "$tunnel_detail"
        printf 'INTERNET_STATUS=%s\n' "$internet_status"
        printf 'INTERNET_TARGET=%s\n' "$internet_target"
        printf 'NETWORK_UPDATED=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$tmp_file"
    mv -f "$tmp_file" "$NETWORK_FILE"
}

# ============================================================
# Проверка профилей Remmina
# ============================================================

remmina_check() {
    local total=0
    local good=0
    local bad=0
    local file value

    echo "Каталог профилей: $PROFILE_DIR"
    echo

    if [ ! -d "$PROFILE_DIR" ]; then
        echo "ОШИБКА: каталог профилей Remmina не найден."
        echo "Проверьте XDG_DATA_HOME или наличие ~/.local/share/remmina."
        return 1
    fi

    while IFS= read -r -d '' file; do
        total=$((total + 1))
        value=$(awk -F= '$1 == "keyboard_grab" { value=$2 } END { print value }' "$file" 2>/dev/null)
        if [ "$value" = "1" ]; then
            good=$((good + 1))
            printf '[OK]       %s — keyboard_grab=1\n' "${file#"$PROFILE_DIR"/}"
        else
            bad=$((bad + 1))
            if [ -z "$value" ]; then value="отсутствует"; fi
            printf '[ИСПРАВИТЬ] %s — keyboard_grab=%s\n' "${file#"$PROFILE_DIR"/}" "$value"
        fi
    done < <(find "$PROFILE_DIR" -type f -name '*.remmina' -print0 2>/dev/null)

    echo
    printf 'Всего профилей: %s; настроены: %s; требуют исправления: %s\n' "$total" "$good" "$bad"

    if [ "$total" -eq 0 ]; then
        echo "Файлы *.remmina не найдены."
        return 1
    fi
    [ "$bad" -eq 0 ]
}

remmina_fix() {
    local total=0
    local fixed=0
    local failed=0
    local file

    if [ ! -d "$PROFILE_DIR" ]; then
        echo "ОШИБКА: каталог профилей Remmina не найден: $PROFILE_DIR"
        return 1
    fi

    while IFS= read -r -d '' file; do
        total=$((total + 1))
        if [ ! -w "$file" ]; then
            printf '[ОШИБКА] Нет прав на запись: %s\n' "${file#"$PROFILE_DIR"/}"
            failed=$((failed + 1))
            continue
        fi

        # Сохраняем исходный профиль перед изменением.
        if ! cp -p "$file" "$file.bak"; then
            failed=$((failed + 1))
            printf '[ОШИБКА] Не удалось создать резервную копию: %s\n' "${file#"$PROFILE_DIR"/}"
            continue
        fi

        if grep -q '^keyboard_grab=' "$file" 2>/dev/null; then
            if sed -i 's/^keyboard_grab=.*/keyboard_grab=1/' "$file"; then
                fixed=$((fixed + 1))
                printf '[OK] %s — keyboard_grab=1 (резервная копия .bak)\n' "${file#"$PROFILE_DIR"/}"
            else
                cp -p "$file.bak" "$file"
                failed=$((failed + 1))
                printf '[ОШИБКА] Не удалось изменить: %s\n' "${file#"$PROFILE_DIR"/}"
            fi
        else
            if printf '\nkeyboard_grab=1\n' >> "$file"; then
                fixed=$((fixed + 1))
                printf '[OK] %s — параметр добавлен (резервная копия .bak)\n' "${file#"$PROFILE_DIR"/}"
            else
                cp -p "$file.bak" "$file"
                failed=$((failed + 1))
                printf '[ОШИБКА] Не удалось добавить параметр: %s\n' "${file#"$PROFILE_DIR"/}"
            fi
        fi
    done < <(find "$PROFILE_DIR" -type f -name '*.remmina' -print0 2>/dev/null)

    echo
    printf 'Профилей найдено: %s; исправлено: %s; ошибок: %s\n' "$total" "$fixed" "$failed"
    if [ "$total" -eq 0 ]; then echo "Файлы *.remmina не найдены."; fi
    echo
    echo "Если Remmina уже запущена, полностью завершите её и запустите заново, чтобы она перечитала изменённые профили."
    [ "$failed" -eq 0 ] && [ "$total" -gt 0 ]
}

remmina_launch() {
    if ! command -v remmina >/dev/null 2>&1; then
        echo "ОШИБКА: команда remmina не найдена в PATH."
        return 1
    fi

    nohup remmina >/dev/null 2>&1 &
    echo "Remmina запущена (PID $!)."
}

# ============================================================
# STATUS
# ============================================================

status_monitor() {

    MONITOR_RUNNING="NO"

    if [ -f "$PID_FILE" ]
    then

        PID=$(cat "$PID_FILE" 2>/dev/null)

        if [ -n "$PID" ] &&
           kill -0 "$PID" 2>/dev/null
        then
            MONITOR_RUNNING="YES"
        fi
    fi

    echo "=========================================="
    echo "           RDP MONITOR STATUS"
    echo "=========================================="
    echo

    if [ "$MONITOR_RUNNING" = "YES" ]
    then
        echo "Monitor : RUNNING"
        echo "PID     : $PID"
    else
        echo "Monitor : STOPPED"
    fi

    echo

    # --------------------------------------------------------
    # Remmina
    # --------------------------------------------------------

    REMMINA_PID=$(get_remmina_pid)
    RDP_PEER=$(get_rdp_peer)

    if [ -n "$RDP_PEER" ]
    then
        echo "RDP     : CONNECTED"
        echo "Peer    : $RDP_PEER"
    else
        echo "RDP     : DISCONNECTED"
    fi

    if [ -n "$REMMINA_PID" ]
    then
        echo "Remmina : RUNNING"
        echo "PID     : $REMMINA_PID"
    else
        echo "Remmina : not detected"
    fi

    echo

    # --------------------------------------------------------
    # Состояние VPN-интерфейса и интернета
    # --------------------------------------------------------

    if [ -f "$NETWORK_FILE" ]; then
        # Файл создаёт network_refresh; выводим только ожидаемые поля.
        TUNNEL_STATUS=$(sed -n 's/^TUNNEL_STATUS=//p' "$NETWORK_FILE" | head -1)
        TUNNEL_DETAIL=$(sed -n 's/^TUNNEL_DETAIL=//p' "$NETWORK_FILE" | head -1)
        INTERNET_STATUS=$(sed -n 's/^INTERNET_STATUS=//p' "$NETWORK_FILE" | head -1)
        INTERNET_TARGET=$(sed -n 's/^INTERNET_TARGET=//p' "$NETWORK_FILE" | head -1)
        NETWORK_UPDATED=$(sed -n 's/^NETWORK_UPDATED=//p' "$NETWORK_FILE" | head -1)
        echo "VPN $VPN_INTERFACE     : ${TUNNEL_STATUS:-UNKNOWN} (${TUNNEL_DETAIL:-нет данных})"
        echo "Internet           : ${INTERNET_STATUS:-UNKNOWN} (${INTERNET_TARGET:-не проверено})"
        echo "Network checked    : ${NETWORK_UPDATED:-неизвестно}"
    else
        echo "VPN $VPN_INTERFACE     : проверка ожидает запуска"
        echo "Internet           : проверка ожидает запуска"
    fi

    echo
    echo "Remmina profiles   : $PROFILE_DIR"
    if [ -d "$PROFILE_DIR" ]; then
        PROFILE_TOTAL=$(find "$PROFILE_DIR" -type f -name '*.remmina' 2>/dev/null | wc -l)
        PROFILE_BAD=$(find "$PROFILE_DIR" -type f -name '*.remmina' -print0 2>/dev/null | while IFS= read -r -d '' file; do
            value=$(awk -F= '$1 == "keyboard_grab" { v=$2 } END { print v }' "$file" 2>/dev/null)
            [ "$value" = "1" ] || printf 'x
'
        done | wc -l)
        echo "Profiles           : $PROFILE_TOTAL total; $PROFILE_BAD need fixing"
    else
        echo "Profiles           : каталог не найден"
    fi

    echo

    # --------------------------------------------------------
    # State file
    # --------------------------------------------------------

    if [ -f "$STATE_FILE" ]
    then
        echo "------------------------------------------"
        echo "Saved state:"
        cat "$STATE_FILE"
    fi

    echo

    # --------------------------------------------------------
    # Alarm
    # --------------------------------------------------------

    if [ -f "$ALARM_PID_FILE" ]
    then

        ALARM_PID=$(cat "$ALARM_PID_FILE" 2>/dev/null)

        if [ -n "$ALARM_PID" ] &&
           kill -0 "$ALARM_PID" 2>/dev/null
        then
            echo "Alarm   : RUNNING"
            echo "Alarm PID: $ALARM_PID"
        else
            echo "Alarm   : OFF (stale PID file)"
        fi

    else

        echo "Alarm   : OFF"

    fi

    echo "=========================================="
}

# ============================================================
# SNOOZE
# ============================================================

snooze_monitor() {

    if [ ! -f "$PID_FILE" ]
    then
        echo "RDP monitor is not running."
        exit 1
    fi

    PID=$(cat "$PID_FILE" 2>/dev/null)

    if [ -z "$PID" ] ||
       ! kill -0 "$PID" 2>/dev/null
    then
        echo "RDP monitor is not running."
        exit 1
    fi

    NOW=$(date +%s)
    SNOOZE_UNTIL=$((NOW + SNOOZE_TIME))

    echo "$SNOOZE_UNTIL" > "$SNOOZE_FILE"

    stop_alarm

    echo "Alarm snoozed for ${SNOOZE_TIME} seconds."
    echo "Until: $(date -d "@$SNOOZE_UNTIL" '+%H:%M:%S')"
}

# =========================
# GUI
# =========================

run_gui() {
    if [ ! -x "$SCRIPT_DIR/rdp-monitor-gui.tcl" ]; then
        echo "Ошибка: GUI не найден или не является исполняемым:"
        echo "$SCRIPT_DIR/rdp-monitor-gui.tcl"
        exit 1
    fi

    exec wish "$SCRIPT_DIR/rdp-monitor-gui.tcl"
}


start_gui() {
    if [ ! -x "$SCRIPT_DIR/rdp-monitor-gui.tcl" ]; then
        echo "Ошибка: GUI не найден или не является исполняемым:"
        echo "$SCRIPT_DIR/rdp-monitor-gui.tcl"
        return 1
    fi

    # GUI already running.
    if [ -f "$GUI_PID_FILE" ]; then
        GUI_PID=$(cat "$GUI_PID_FILE" 2>/dev/null)

        if [ -n "$GUI_PID" ] &&
           kill -0 "$GUI_PID" 2>/dev/null
        then
            return 0
        fi

        rm -f "$GUI_PID_FILE"
    fi

    nohup wish "$SCRIPT_DIR/rdp-monitor-gui.tcl" \
        >/dev/null 2>&1 &

    echo $! > "$GUI_PID_FILE"

    return 0
}


autostart() {
    start_monitor
    start_gui
}

# =========================
# COMMAND DISPATCHER
# =========================

case "$1" in

    monitor)
        monitor
        ;;

    start)
        start_monitor
        ;;

    autostart)
        autostart
        ;;

    stop)
        stop_monitor
        ;;

    status)
        status_monitor
        ;;

    snooze)
        snooze_monitor
        ;;

    gui)
        run_gui
        ;;

    network-refresh)
        network_refresh
        ;;

    remmina-check)
        remmina_check
        ;;

    remmina-fix)
        remmina_fix
        ;;

    remmina-launch)
        remmina_launch
        ;;

    *)
        echo
        echo "RDP Monitor"
        echo
        echo "Использование:"
        echo
        echo "  $0 start       - запустить монитор"
        echo "  $0 autostart   - запустить монитор и GUI"
        echo "  $0 stop        - остановить монитор"
        echo "  $0 status      - показать состояние"
        echo "  $0 snooze      - отложить тревогу на 1 минуту"
        echo "  $0 gui         - открыть GUI"
        echo "  $0 network-refresh - обновить проверки сети"
        echo "  $0 remmina-check   - проверить keyboard_grab во всех профилях"
        echo "  $0 remmina-fix     - установить keyboard_grab=1 во всех профилях"
        echo "  $0 remmina-launch  - запустить Remmina"
        echo
        exit 1
        ;;

esac

#!/usr/bin/wish

# ==========================================
# RDP Monitor GUI
# Tcl/Tk frontend for rdp-monitor.sh
# ==========================================

set script_dir [file dirname [file normalize [info script]]]
set monitor_script [file join $script_dir "rdp-monitor.sh"]
set gui_pid_file [file join $script_dir "rdp-monitor.gui.pid"]

# Register this GUI instance.
set gui_pid [pid]
set f [open $gui_pid_file w]
puts $f $gui_pid
close $f


# ---------- Colors ----------
set bg_color "#f2f2f2"
set header_color "#d9d9d9"
set text_color "#202020"
set green_color "#16803c"
set red_color "#c62828"
set yellow_color "#b26a00"

set refresh_after_id ""

# ---------- Fonts ----------
font create StatusFont \
    -family Courier \
    -size 11

font create HeaderFont \
    -family Arial \
    -size 16 \
    -weight bold

font create IndicatorFont \
    -family Arial \
    -size 10 \
    -weight bold


# ==========================================
# Window
# ==========================================

wm title . "RDP Monitor"
wm resizable . 0 0


# ==========================================
# Main layout
# ==========================================

frame .header \
    -background $header_color \
    -bd 1 \
    -relief solid

grid .header \
    -row 0 \
    -column 0 \
    -sticky ew


frame .main \
    -background $bg_color

grid .main \
    -row 1 \
    -column 0 \
    -sticky nsew \
    -padx 10 \
    -pady 10


frame .buttons \
    -background $bg_color

grid .buttons \
    -row 2 \
    -column 0 \
    -sticky ew \
    -padx 10 \
    -pady {0 10}


grid rowconfigure . 1 -weight 1
grid columnconfigure . 0 -weight 1


# ==========================================
# Header
# ==========================================

label .header.title \
    -text "RDP MONITOR" \
    -font HeaderFont \
    -background $header_color \
    -foreground $text_color \
    -pady 10

pack .header.title \
    -side left \
    -padx 15


frame .header.indicator \
    -background $header_color

pack .header.indicator \
    -side right \
    -padx 15


label .header.indicator.dot \
    -text "●" \
    -font {Arial 20 bold} \
    -background $header_color \
    -foreground $yellow_color

pack .header.indicator.dot \
    -side left


label .header.indicator.text \
    -text "ПРОВЕРКА..." \
    -font IndicatorFont \
    -background $header_color \
    -foreground $text_color

pack .header.indicator.text \
    -side left \
    -padx 5


# ==========================================
# Status
# ==========================================

text .main.status \
    -font StatusFont \
    -background "#ffffff" \
    -foreground $text_color \
    -borderwidth 1 \
    -relief solid \
    -wrap none \
    -padx 14 \
    -pady 12 \
    -height 20 \
    -width 80 \
    -state disabled

pack .main.status \
    -fill both \
    -expand 1


# ==========================================
# Buttons
# ==========================================

# Row containers must exist before creating their child buttons.
frame .buttons.row1 -background $bg_color
frame .buttons.row2 -background $bg_color
pack .buttons.row1 .buttons.row2 -side top -fill x -anchor w

button .buttons.row1.refresh \
    -text "Обновить" -width 12 -command refresh_status
button .buttons.row1.snooze \
    -text "Отложить 1 мин" -width 14 -command snooze_alarm
button .buttons.row1.start \
    -text "Запустить" -width 12 -command start_monitor
button .buttons.row1.stop \
    -text "Остановить" -width 12 -command stop_monitor
button .buttons.row1.exit \
    -text "Выход" -width 9 -command exit_gui

pack .buttons.row1.refresh .buttons.row1.snooze .buttons.row1.start \
     .buttons.row1.stop .buttons.row1.exit -side left -padx 3 -pady 3

button .buttons.row2.network \
    -text "Проверить сеть" -width 16 -command check_network
button .buttons.row2.profile_check \
    -text "Проверить профили" -width 17 -command check_profiles
button .buttons.row2.profile_fix \
    -text "Исправить keyboard_grab" -width 22 -command fix_profiles
button .buttons.row2.remmina \
    -text "Запустить Remmina" -width 17 -command launch_remmina

pack .buttons.row2.network .buttons.row2.profile_check \
     .buttons.row2.profile_fix .buttons.row2.remmina -side left -padx 3 -pady 3

# ==========================================
# Monitor interaction
# ==========================================

proc run_monitor {command} {
    global monitor_script

    if {![file exists $monitor_script]} {
        return "ОШИБКА: файл не найден:\n$monitor_script"
    }

    if {![file executable $monitor_script]} {
        return "ОШИБКА: файл не является исполняемым:\n$monitor_script"
    }

    set result ""

    if {[catch {
        set result [exec $monitor_script $command 2>&1]
    } error]} {
        set result $error
    }

    return $result
}


# ==========================================
# Network and Remmina profile actions
# ==========================================

proc request_network_refresh {} {
    global monitor_script
    # Launch in background: network timeouts must not freeze the GUI.
    catch {exec -- $monitor_script network-refresh > /dev/null 2>@1 &}
}

proc show_result_window {title content} {
    set w .result
    if {[winfo exists $w]} { destroy $w }
    toplevel $w
    wm title $w $title
    wm geometry $w 760x420
    frame $w.body
    pack $w.body -fill both -expand 1 -padx 8 -pady 8
    scrollbar $w.body.scroll -orient vertical -command [list $w.body.text yview]
    text $w.body.text -wrap none -font StatusFont -yscrollcommand [list $w.body.scroll set] -width 100 -height 22
    pack $w.body.scroll -side right -fill y
    pack $w.body.text -side left -fill both -expand 1
    $w.body.text insert end $content
    $w.body.text configure -state disabled
    button $w.close -text "Закрыть" -command [list destroy $w]
    pack $w.close -pady {0 8}
    raise $w
}

proc check_profiles {} {
    set result [run_monitor remmina-check]
    show_result_window "Проверка профилей Remmina" $result
    refresh_status
}

proc fix_profiles {} {
    set result [run_monitor remmina-fix]
    show_result_window "Исправление профилей Remmina" $result
    refresh_status
}

proc launch_remmina {} {
    set result [run_monitor remmina-launch]
    show_result_window "Запуск Remmina" $result
    refresh_status
}

proc check_network {} {
    request_network_refresh
    refresh_status
}

# ==========================================
# Indicator
# ==========================================

proc update_indicator {status} {
    global green_color red_color yellow_color

    if {[string match "*RDP     : CONNECTED*" $status]} {
        .header.indicator.dot configure -foreground $green_color
        .header.indicator.text configure -text "RDP ПОДКЛЮЧЕНО"

    } elseif {[string match "*RDP     : DISCONNECTED*" $status]} {
        .header.indicator.dot configure -foreground $red_color
        .header.indicator.text configure -text "RDP НЕТ СОЕДИНЕНИЯ"

    } else {
        .header.indicator.dot configure -foreground $yellow_color
        .header.indicator.text configure -text "МОНИТОР НЕ ЗАПУЩЕН"
    }

    if {[string match "*Alarm   : RUNNING*" $status]} {
        .header.indicator.dot configure -foreground $red_color
        .header.indicator.text configure -text "ТРЕВОГА!"
    }
}


# ==========================================
# Automatic size calculation
# ==========================================

proc fit_window {} {
    update idletasks

    # Required width of the status text.
    set content [.main.status get 1.0 end]
    set max_text_width 0

    foreach line [split $content "\n"] {
        set w [font measure StatusFont $line]
        if {$w > $max_text_width} {
            set max_text_width $w
        }
    }

    # Requested sizes of all fixed parts.
    set header_width [winfo reqwidth .header]
    set buttons_width [winfo reqwidth .buttons]

    # Text area width.
    set status_width [expr {$max_text_width + 50}]

    set required_width $status_width

    if {$header_width > $required_width} {
        set required_width $header_width
    }

    if {$buttons_width > $required_width} {
        set required_width $buttons_width
    }

    # Minimum width.
    if {$required_width < 720} {
        set required_width 720
    }

    # Maximum width: 90% of screen.
    set max_width [expr {int([winfo screenwidth .] * 0.90)}]

    if {$required_width > $max_width} {
        set required_width $max_width
    }

    # Height is based on the actual requested sizes of header,
    # status area and buttons. No scrollbar.
    set header_height [winfo reqheight .header]
    set buttons_height [winfo reqheight .buttons]
    set status_height [winfo reqheight .main.status]

    set required_height [expr {
        $header_height +
        $status_height +
        $buttons_height +
        30
    }]

    # Minimum height.
    if {$required_height < 480} {
        set required_height 480
    }

    # Maximum height: 85% of screen.
    set max_height [expr {int([winfo screenheight .] * 0.85)}]

    if {$required_height > $max_height} {
        set required_height $max_height
    }

    wm geometry . "${required_width}x${required_height}"

    # Force final geometry calculation, then lock it.
    update idletasks

    set actual_width [winfo width .]
    set actual_height [winfo height .]

    wm minsize . $actual_width $actual_height
    wm maxsize . $actual_width $actual_height
    wm resizable . 0 0
}


# ==========================================
# Refresh
# ==========================================

proc refresh_status {} {
    global last_network_request
    set now [clock seconds]
    if {![info exists last_network_request] || ($now - $last_network_request) >= 15} {
        set last_network_request $now
        request_network_refresh
    }
    set result [run_monitor status]

    .main.status configure -state normal
    .main.status delete 1.0 end
    .main.status insert end $result
    .main.status configure -state disabled

    .main.status see 1.0

    update_indicator $result
}


# ==========================================
# Automatic refresh
# ==========================================

proc schedule_refresh {} {
    global refresh_after_id

    if {$refresh_after_id ne ""} {
        after cancel $refresh_after_id
    }

    set refresh_after_id [after 2000 automatic_refresh]
}


proc automatic_refresh {} {
    global refresh_after_id

    set refresh_after_id ""

    refresh_status
    schedule_refresh
}


# ==========================================
# Buttons
# ==========================================

proc start_monitor {} {
    run_monitor start
    refresh_status
}


proc stop_monitor {} {
    run_monitor stop
    refresh_status
}


proc snooze_alarm {} {
    run_monitor snooze
    refresh_status
}


# ==========================================
# Exit
# ==========================================

proc exit_gui {} {
    global refresh_after_id gui_pid_file

    if {$refresh_after_id ne ""} {
        after cancel $refresh_after_id
        set refresh_after_id ""
    }

    file delete -force $gui_pid_file

    destroy .
}

wm protocol . WM_DELETE_WINDOW exit_gui


# ==========================================
# Start
# ==========================================

request_network_refresh
refresh_status
fit_window
schedule_refresh

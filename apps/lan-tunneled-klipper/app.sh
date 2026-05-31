
source /useremain/rinkhals/.current/tools.sh

APP_ROOT=$(dirname $(realpath $0))

status() {
    mkdir -p /tmp/lan_tunnel
    STATUS=$(cat /tmp/lan_tunnel/.status 2> /dev/null)

    if [ "$STATUS" == "1" ]; then
        report_status $APP_STATUS_STARTED
    else
        report_status $APP_STATUS_STOPPED
    fi
}
start() {
        (
                mkdir -p /tmp/lan_tunnel
                echo 1 > /tmp/lan_tunnel/.status
                log "Set network"
                ifconfig eth1 down
                ifconfig eth1 hw ether 00:E0:4C:44:4E:50
                ifconfig eth1 up
                ifconfig eth1 192.168.10.67 netmask 255.255.255.0 up

                log "Started Watchdog $EXAMPLE_VERSION from $APP_ROOT"
                sleep 5

                cd "$APP_ROOT"
                chmod +x ./lanModeWatchdog.sh
                ./lanModeWatchdog.sh &
                cd "$APP_ROOT"
                chmod +x ./pwm_jingle.sh
                ./pwm_jingle.sh start
                sleep 1
                log "Started lan_tunnel $EXAMPLE_VERSION from $APP_ROOT"

                sleep 17
                kill_by_name gklib

                log "MCU Reset"
                echo 116 > /sys/class/gpio/export 2>/dev/null || true
                echo out > /sys/class/gpio/gpio116/direction
                echo 0 > /sys/class/gpio/gpio116/value
                sleep 1
                echo 1 > /sys/class/gpio/gpio116/value

                log "Socat start"
                sleep 2
                socat -ly -d -d -T 10 TCP-LISTEN:7003,reuseaddr,fork,nodelay,keepalive FILE:/dev/ttyS3,raw,echo=0,clocal,crtscts=0 &
                socat -ly -d -d -T 10 TCP-LISTEN:7005,reuseaddr,fork,nodelay,keepalive FILE:/dev/ttyS5,raw,echo=0,clocal,crtscts=0 &
                cd "$APP_ROOT"
                chmod +x ./pwm_jingle.sh
                ./pwm_jingle.sh imperial

                # --- GKAPI PATCH/Fake server logic (only for KS1) ---
                if [ "${KOBRA_MODEL_CODE:-}" = "KS1" ]; then
                    "$APP_ROOT/gkapi_patched_run.sh" ensure-original || true
                    killall -q gkapi 2>/dev/null || true
                    nohup python3 "$APP_ROOT/fake_gkapi_server.py" > /tmp/fake_gkapi.log 2>&1 &
                fi
        ) &
}
    
stop() {
    (
        mkdir -p /tmp/lan_tunnel
        echo 0 > /tmp/lan_tunnel/.status
        log "Stopped lan_tunnel"
        kill_by_name ":70"
        #log "Klipperscreen stoping"
        #cd ~/apps/80-klipperscreen/
        #chmod +x ./app.sh
        #./app.sh stop &
        sleep 5	
        log "MCU Reset"
        echo 116 > /sys/class/gpio/export 2>/dev/null || true
        echo out > /sys/class/gpio/gpio116/direction
        echo 0 > /sys/class/gpio/gpio116/value
        sleep 1
        echo 1 > /sys/class/gpio/gpio116/value    
        sleep 2

        # --- GKAPI PATCH/Fake server logic (only for KS1) ---
        if [ "${KOBRA_MODEL_CODE:-}" = "KS1" ]; then
            for pid in $(ps | grep 'python3 /home/janni/git/Rinkhals.apps.publish/Rinkhals.apps/apps/lan-tunneled-klipper/fake_gkapi_server.py' | grep -v grep | awk '{print $1}'); do
                kill -9 "$pid" 2>/dev/null || true
            done
            "$APP_ROOT/gkapi_patched_run.sh" run-patched || true
        fi

        cd /userdata/app/gk
        LD_LIBRARY_PATH=/userdata/app/gk:$LD_LIBRARY_PATH \
                ./gklib -a /tmp/unix_uds1 /userdata/app/gk/printer_data/config/printer.generated.cfg &> $RINKHALS_ROOT/logs/gklib.log &
        log "gklib started"  
    ) &         
}

case "$1" in
    status)
        status
        ;;
    start)
        start
        ;;
    stop)
        stop
        ;;
    *)
        echo "Usage: $0 {status|start|stop}" >&2
        exit 1
        ;;
esac

#!/usr/bin/env bash

HOST="localhost"
PORT="18086"
INTERVAL=120

QUERY_CMD='{"id":2017,"method":"Printer/QueryLanPrintStatus","params":{}}'
OPEN_CMD='{"id":2015,"method":"Printer/OpenLanPrint","params":{}}'

while true; do
    RESPONSE=$(printf '%s\003' "$QUERY_CMD" | nc "$HOST" "$PORT" 2>/dev/null)

    if echo "$RESPONSE" | grep -q '"open":1'; then
        echo "$(date) - LAN mode already open"
    else
        echo "$(date) - LAN mode closed, opening..."
        printf '%s\003' "$OPEN_CMD" | nc "$HOST" "$PORT" 2>/dev/null
    fi

    sleep "$INTERVAL"
done

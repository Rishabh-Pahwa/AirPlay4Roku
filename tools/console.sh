#!/usr/bin/env bash
# Usage: tools/console.sh <seconds> [roku-ip]  -- capture BrightScript debug console (unbuffered)
ROKU_IP="${2:-${ROKU_IP:-192.168.1.16}}"
timeout "${1:-20}" bash -c "exec 3<>/dev/tcp/$ROKU_IP/8085; stdbuf -o0 tr -d '\r' <&3"

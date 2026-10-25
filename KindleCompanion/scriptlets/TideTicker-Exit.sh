#!/bin/sh
# Name: TideTicker Exit
# Author: rongcat

APP_ID="com.xlogic.tideticker.kindle"

/usr/bin/lipc-set-prop com.lab126.appmgrd stop "$APP_ID" >/dev/null 2>&1 || true
/usr/bin/lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true
echo "TideTicker stopped; normal sleep restored"

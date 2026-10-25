#!/bin/sh
# Name: TideTicker Uninstall
# Author: rongcat

APP_ID="com.xlogic.tideticker.kindle"
APP_DB="/var/local/appreg.db"

/usr/bin/lipc-set-prop com.lab126.appmgrd stop "$APP_ID" >/dev/null 2>&1 || true
/usr/bin/lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true

if [ -x /usr/bin/sqlite3 ] && [ -r "$APP_DB" ]; then
    /usr/bin/sqlite3 "$APP_DB" <<SQL
.timeout 5000
BEGIN IMMEDIATE;
DELETE FROM properties WHERE handlerId = '$APP_ID';
DELETE FROM handlerIds WHERE handlerId = '$APP_ID';
COMMIT;
SQL
fi

echo "TideTicker registration removed; delete /mnt/us/tideticker-companion over USB to remove its files"

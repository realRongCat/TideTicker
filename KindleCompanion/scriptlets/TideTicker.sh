#!/bin/sh
# Name: TideTicker
# Author: rongcat

APP_ID="com.xlogic.tideticker.kindle"
APP_DIR="/mnt/us/tideticker-companion/waf"
APP_DB="/var/local/appreg.db"
STATE_DIR="/mnt/us/tideticker-companion/state"
LOG_FILE="$STATE_DIR/launcher.log"

mkdir -p "$STATE_DIR"
exec >> "$LOG_FILE" 2>&1
date

fail() {
    echo "ERROR: $1"
    /usr/bin/lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true
    exit 1
}

[ -x /usr/bin/mesquite ] || fail "mesquite is unavailable"
[ -x /usr/bin/sqlite3 ] || fail "sqlite3 is unavailable"
[ -r "$APP_DB" ] || fail "appreg.db is unavailable"
[ -r "$APP_DIR/config.xml" ] || fail "config.xml is missing"
[ -r "$APP_DIR/index.html" ] || fail "index.html is missing"
[ -r "$APP_DIR/settings.js" ] || fail "settings.js is missing"

if [ ! -f "$STATE_DIR/appreg.db.before-tideticker" ]; then
    cp "$APP_DB" "$STATE_DIR/appreg.db.before-tideticker" || fail "could not back up appreg.db"
fi

/usr/bin/sqlite3 "$APP_DB" <<SQL || fail "could not register TideTicker"
.timeout 5000
BEGIN IMMEDIATE;
INSERT OR IGNORE INTO handlerIds (handlerId) VALUES ('$APP_ID');
DELETE FROM properties WHERE handlerId = '$APP_ID';
INSERT INTO properties (handlerId, name, value) VALUES
  ('$APP_ID', 'command', '/usr/bin/mesquite -l $APP_ID -c file://$APP_DIR/'),
  ('$APP_ID', 'framework', ''),
  ('$APP_ID', 'unloadPolicy', 'unloadOnPause');
COMMIT;
SQL

/usr/bin/lipc-set-prop com.lab126.powerd preventScreenSaver 1 || fail "could not keep the display awake"
/usr/bin/lipc-set-prop com.lab126.appmgrd start "app://$APP_ID" || fail "could not start TideTicker"
echo "TideTicker started"

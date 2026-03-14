#!/bin/bash
# Perforce Game Server — Dev Entrypoint
# Fast startup, security level 0, no SSL. Designed for local development.
# Built by ButterStack — https://butterstack.com

set -e

P4ROOT="${P4ROOT:-/data/p4depot/root}"
P4LOG="${P4LOG:-/data/p4depot/logs/log}"
P4PORT="${P4PORT:-1666}"
P4USER="${P4USER:-super}"
P4PASSWD="${P4PASSWD:-dev123}"
P4REST_PORT="${P4REST_PORT:-8090}"
ENGINE="${ENGINE:-unreal}"
CASE_INSENSITIVE="${CASE_INSENSITIVE:-1}"
UNICODE="${UNICODE:-1}"

# Ensure data directories exist
mkdir -p "$P4ROOT" "$(dirname "$P4LOG")"

# Initialize server on first run
if [ ! -f "$P4ROOT/db.config" ]; then
    echo "First run — initializing Perforce server..."

    INIT_ARGS="-r $P4ROOT -J $P4ROOT/journal"

    # Case insensitivity (standard for UE/Unity on Windows)
    if [ "$CASE_INSENSITIVE" = "1" ]; then
        INIT_ARGS="$INIT_ARGS -C1"
        echo "  Case insensitive mode enabled (recommended for game dev)"
    fi

    # Unicode mode
    if [ "$UNICODE" = "1" ]; then
        p4d $INIT_ARGS -xi
        echo "  Unicode mode enabled"
    fi
else
    echo "Existing data detected. Running schema upgrade..."
    p4d -r "$P4ROOT" -J "$P4ROOT/journal" -xu
    echo "Schema upgrade complete."
fi

# Start p4d as daemon for initial setup
echo "Starting Perforce server for setup..."
p4d -r "$P4ROOT" -p "$P4PORT" -L "$P4LOG" -J "$P4ROOT/journal" -d
sleep 2

# Wait for server
until p4 -u "$P4USER" -p "localhost:$P4PORT" info > /dev/null 2>&1; do
    echo "Waiting for p4d..."
    sleep 1
done
echo "Perforce server is running."

# Create super user if it doesn't exist
LOGIN_OUTPUT=$(p4 -u "$P4USER" -p "localhost:$P4PORT" login 2>&1 || true)
if echo "$LOGIN_OUTPUT" | grep -q "doesn't exist"; then
    echo "Creating user $P4USER..."
    p4 -u "$P4USER" -p "localhost:$P4PORT" user -o \
        | p4 -u "$P4USER" -p "localhost:$P4PORT" user -i -f
    LOGIN_OUTPUT=$(p4 -u "$P4USER" -p "localhost:$P4PORT" login 2>&1 || true)
fi

# Set password if not set
if echo "$LOGIN_OUTPUT" | grep -q "no password"; then
    echo "Setting password for $P4USER..."
    printf '%s\n%s\n' "$P4PASSWD" "$P4PASSWD" \
        | p4 -u "$P4USER" -p "localhost:$P4PORT" passwd
    printf '%s\n' "$P4PASSWD" | p4 -u "$P4USER" -p "localhost:$P4PORT" login
fi

# Set security level 0 (no password expiry)
p4 -u "$P4USER" -p "localhost:$P4PORT" configure set security=0 2>/dev/null || true
p4 -u "$P4USER" -p "localhost:$P4PORT" configure set dm.password.minlength=0 2>/dev/null || true

# Ensure we're logged in
printf '%s\n' "$P4PASSWD" | p4 -u "$P4USER" -p "localhost:$P4PORT" login 2>/dev/null || true

# Fix expired password if needed
if p4 -u "$P4USER" -p "localhost:$P4PORT" depots 2>&1 | grep -q "password has expired"; then
    echo "Password expired — fixing..."
    TEMP_PASS="TempFixPass789"
    printf '%s\n%s\n%s\n' "$P4PASSWD" "$TEMP_PASS" "$TEMP_PASS" \
        | p4 -u "$P4USER" -p "localhost:$P4PORT" passwd
    printf '%s\n' "$TEMP_PASS" | p4 -u "$P4USER" -p "localhost:$P4PORT" login
    p4 -u "$P4USER" -p "localhost:$P4PORT" configure set security=0
    p4 -u "$P4USER" -p "localhost:$P4PORT" configure set dm.password.minlength=0
    printf '%s\n%s\n%s\n' "$TEMP_PASS" "$P4PASSWD" "$P4PASSWD" \
        | p4 -u "$P4USER" -p "localhost:$P4PORT" passwd
    printf '%s\n' "$P4PASSWD" | p4 -u "$P4USER" -p "localhost:$P4PORT" login
    echo "Password fix applied."
fi

# Grant super user protections
echo "Protections:" > /tmp/protect.txt
echo "	super user $P4USER * //..." >> /tmp/protect.txt
echo "	write user * * //..." >> /tmp/protect.txt
p4 -u "$P4USER" -p "localhost:$P4PORT" protect -i < /tmp/protect.txt 2>/dev/null || true
rm -f /tmp/protect.txt

# Apply typemap
setup-typemap.sh || echo "WARNING: Typemap setup failed (non-fatal)"

# Start REST API webserver in background
start_webserver() {
    if [ "$P4REST_PORT" = "0" ]; then
        echo "REST API disabled (P4REST_PORT=0)."
        return
    fi

    sleep 3
    until p4 -u "$P4USER" -p "localhost:$P4PORT" info > /dev/null 2>&1; do
        sleep 2
    done

    printf '%s\n' "$P4PASSWD" | p4 -u "$P4USER" -p "localhost:$P4PORT" login 2>/dev/null || true

    if p4 -u "$P4USER" -p "localhost:$P4PORT" webserver start -p "$P4REST_PORT" 2>/dev/null; then
        echo "REST API available at http://localhost:$P4REST_PORT/api/version"

        REST_TICKET=$(printf '%s\n' "$P4PASSWD" | p4 -u "$P4USER" -p "localhost:$P4PORT" login -h restapi -p 2>/dev/null | tail -1)
        if [ -n "$REST_TICKET" ]; then
            echo "$REST_TICKET" > /data/p4_rest_ticket
            echo "REST API ticket saved to /data/p4_rest_ticket"
            echo "  Usage: curl -u $P4USER:$REST_TICKET http://localhost:$P4REST_PORT/api/v0/depot"
        fi
    else
        echo "WARNING: Failed to start REST API (requires p4d 2025.2+)"
    fi
}

# Kill daemon — we'll restart in foreground
pkill -f "p4d.*$P4PORT" 2>/dev/null || true
sleep 1

# Launch webserver in background
start_webserver &

# Print connection info
echo ""
echo "============================================"
echo "  Perforce Game Server (Dev)"
echo "  Port:     $P4PORT"
echo "  User:     $P4USER"
echo "  Password: $P4PASSWD"
echo "  REST API: http://localhost:$P4REST_PORT"
echo "  Engine:   $ENGINE"
echo ""
echo "  Connect:  p4 -p localhost:$P4PORT -u $P4USER"
echo "============================================"
echo ""

# Start p4d in FOREGROUND (exec replaces shell, keeps container alive)
exec p4d -r "$P4ROOT" -p "$P4PORT" -L "$P4LOG" -J "$P4ROOT/journal"

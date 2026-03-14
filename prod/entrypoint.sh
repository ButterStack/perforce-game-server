#!/bin/bash
# Perforce Game Server — Production Entrypoint
# SSL enabled, security level 3, strong passwords required.
# Built by ButterStack — https://butterstack.com

set -e

P4ROOT="${P4ROOT:-/data/p4depot/root}"
P4LOG="${P4LOG:-/data/p4depot/logs/log}"
P4PORT="${P4PORT:-1666}"
P4USER="${P4USER:-super}"
P4PASSWD="${P4PASSWD}"
P4REST_PORT="${P4REST_PORT:-8090}"
ENGINE="${ENGINE:-unreal}"
CASE_INSENSITIVE="${CASE_INSENSITIVE:-1}"
UNICODE="${UNICODE:-1}"
SSL="${SSL:-1}"
P4SSLDIR="${P4SSLDIR:-/data/ssl}"

# Validate required environment variables
if [ -z "$P4PASSWD" ]; then
    echo "ERROR: P4PASSWD environment variable is required for production."
    echo "  Set it in your docker-compose.yml or pass via: -e P4PASSWD=YourSecurePass123%"
    echo "  Password must be at least 8 characters with mixed case, numbers, and special chars."
    exit 1
fi

if [ ${#P4PASSWD} -lt 8 ]; then
    echo "ERROR: P4PASSWD must be at least 8 characters for production (security level 3)."
    exit 1
fi

# Ensure data directories exist
mkdir -p "$P4ROOT" "$(dirname "$P4LOG")" "$P4SSLDIR"

# SSL certificate setup
if [ "$SSL" = "1" ]; then
    export P4SSLDIR
    if [ ! -f "$P4SSLDIR/privatekey.txt" ]; then
        echo "Generating SSL certificates..."
        # p4d -Gc generates a self-signed certificate pair
        p4d -r "$P4ROOT" -Gc
        # Move generated certs to the SSL directory if not already there
        if [ -f "$P4ROOT/sslkeys/privatekey.txt" ]; then
            cp "$P4ROOT/sslkeys/privatekey.txt" "$P4SSLDIR/"
            cp "$P4ROOT/sslkeys/certificate.txt" "$P4SSLDIR/"
        fi
        echo "SSL certificates generated in $P4SSLDIR"
    else
        echo "Using existing SSL certificates from $P4SSLDIR"
    fi
    P4_LISTEN="ssl:$P4PORT"
    P4_CONNECT="ssl:localhost:$P4PORT"
else
    P4_LISTEN="$P4PORT"
    P4_CONNECT="localhost:$P4PORT"
fi

# Initialize server on first run
if [ ! -f "$P4ROOT/db.config" ]; then
    echo "First run — initializing Perforce server..."

    INIT_ARGS="-r $P4ROOT -J $P4ROOT/journal"

    if [ "$CASE_INSENSITIVE" = "1" ]; then
        INIT_ARGS="$INIT_ARGS -C1"
        echo "  Case insensitive mode enabled"
    fi

    if [ "$UNICODE" = "1" ]; then
        p4d $INIT_ARGS -xi
        echo "  Unicode mode enabled"
    fi
else
    echo "Existing data detected. Running schema upgrade..."
    p4d -r "$P4ROOT" -J "$P4ROOT/journal" -xu
    echo "Schema upgrade complete."
fi

# Trust our own SSL certificate for local connections
if [ "$SSL" = "1" ]; then
    p4 -p "$P4_CONNECT" trust -y 2>/dev/null || true
fi

# Start p4d as daemon for initial setup
echo "Starting Perforce server for setup..."
p4d -r "$P4ROOT" -p "$P4_LISTEN" -L "$P4LOG" -J "$P4ROOT/journal" -d
sleep 3

# Wait for server
until p4 -u "$P4USER" -p "$P4_CONNECT" info > /dev/null 2>&1; do
    echo "Waiting for p4d..."
    sleep 2
done
echo "Perforce server is running."

# Create super user if it doesn't exist
LOGIN_OUTPUT=$(p4 -u "$P4USER" -p "$P4_CONNECT" login 2>&1 || true)
if echo "$LOGIN_OUTPUT" | grep -q "doesn't exist"; then
    echo "Creating user $P4USER..."
    p4 -u "$P4USER" -p "$P4_CONNECT" user -o \
        | p4 -u "$P4USER" -p "$P4_CONNECT" user -i -f
    LOGIN_OUTPUT=$(p4 -u "$P4USER" -p "$P4_CONNECT" login 2>&1 || true)
fi

# Set password if not set
if echo "$LOGIN_OUTPUT" | grep -q "no password"; then
    echo "Setting password for $P4USER..."
    printf '%s\n%s\n' "$P4PASSWD" "$P4PASSWD" \
        | p4 -u "$P4USER" -p "$P4_CONNECT" passwd
    printf '%s\n' "$P4PASSWD" | p4 -u "$P4USER" -p "$P4_CONNECT" login
fi

# Ensure we're logged in before configuring security
printf '%s\n' "$P4PASSWD" | p4 -u "$P4USER" -p "$P4_CONNECT" login 2>/dev/null || true

# Fix expired password if needed (can happen on restart with existing data at security>0)
if p4 -u "$P4USER" -p "$P4_CONNECT" depots 2>&1 | grep -q "password has expired"; then
    echo "Password expired — fixing..."
    TEMP_PASS="TempFixPass789!"
    printf '%s\n%s\n%s\n' "$P4PASSWD" "$TEMP_PASS" "$TEMP_PASS" \
        | p4 -u "$P4USER" -p "$P4_CONNECT" passwd
    printf '%s\n' "$TEMP_PASS" | p4 -u "$P4USER" -p "$P4_CONNECT" login
    # Temporarily lower security to fix password
    p4 -u "$P4USER" -p "$P4_CONNECT" configure set security=0
    printf '%s\n%s\n%s\n' "$TEMP_PASS" "$P4PASSWD" "$P4PASSWD" \
        | p4 -u "$P4USER" -p "$P4_CONNECT" passwd
    printf '%s\n' "$P4PASSWD" | p4 -u "$P4USER" -p "$P4_CONNECT" login
    echo "Password fix applied."
fi

# Set security level 3 (strong passwords required, ticket-based auth)
p4 -u "$P4USER" -p "$P4_CONNECT" configure set security=3 2>/dev/null || true
p4 -u "$P4USER" -p "$P4_CONNECT" configure set dm.password.minlength=8 2>/dev/null || true

# Grant super user protections (lock down by default)
echo "Protections:" > /tmp/protect.txt
echo "	super user $P4USER * //..." >> /tmp/protect.txt
echo "	write user * * //..." >> /tmp/protect.txt
p4 -u "$P4USER" -p "$P4_CONNECT" protect -i < /tmp/protect.txt 2>/dev/null || true
rm -f /tmp/protect.txt

# Apply typemap
setup-typemap.sh || echo "WARNING: Typemap setup failed (non-fatal)"

# Start REST API webserver in background
start_webserver() {
    if [ "$P4REST_PORT" = "0" ]; then
        echo "REST API disabled (P4REST_PORT=0)."
        return
    fi

    sleep 5
    until p4 -u "$P4USER" -p "$P4_CONNECT" info > /dev/null 2>&1; do
        sleep 3
    done

    printf '%s\n' "$P4PASSWD" | p4 -u "$P4USER" -p "$P4_CONNECT" login 2>/dev/null || true

    if p4 -u "$P4USER" -p "$P4_CONNECT" webserver start -p "$P4REST_PORT" 2>/dev/null; then
        echo "REST API available at http://localhost:$P4REST_PORT/api/version"

        REST_TICKET=$(printf '%s\n' "$P4PASSWD" | p4 -u "$P4USER" -p "$P4_CONNECT" login -h restapi -p 2>/dev/null | tail -1)
        if [ -n "$REST_TICKET" ]; then
            echo "$REST_TICKET" > /data/p4_rest_ticket
            echo "REST API ticket saved to /data/p4_rest_ticket"
        fi
    else
        echo "WARNING: Failed to start REST API (requires p4d 2025.2+)"
    fi
}

# Kill daemon — we'll restart in foreground
pkill -f "p4d.*$P4PORT" 2>/dev/null || true
sleep 2

# Launch webserver in background
start_webserver &

# Print connection info
echo ""
echo "============================================"
echo "  Perforce Game Server (Production)"
if [ "$SSL" = "1" ]; then
echo "  Port:     ssl:$P4PORT"
else
echo "  Port:     $P4PORT"
fi
echo "  User:     $P4USER"
echo "  REST API: http://localhost:$P4REST_PORT"
echo "  Engine:   $ENGINE"
echo "  Security: Level 3"
echo ""
if [ "$SSL" = "1" ]; then
echo "  Connect:  p4 -p ssl:localhost:$P4PORT -u $P4USER"
echo "  Trust:    p4 -p ssl:localhost:$P4PORT trust -y"
else
echo "  Connect:  p4 -p localhost:$P4PORT -u $P4USER"
fi
echo "============================================"
echo ""

# Start p4d in FOREGROUND
exec p4d -r "$P4ROOT" -p "$P4_LISTEN" -L "$P4LOG" -J "$P4ROOT/journal"

#!/bin/sh
# Source this helper to write the repository signing key from $PRIV_KEY to a
# temp file with a tight umask, registering cleanup on EXIT.
# Usage:
#   . src/oco-key.sh
#   oco_key_write private.pem
oco_key_write() {
        keyfile=$1
        case "$keyfile" in
                /*) ;;
                *) keyfile="./$keyfile" ;;
        esac
        KEYFILE_CLEANUP="$keyfile"
        trap 'rm -f "$KEYFILE_CLEANUP"' EXIT INT TERM
        ( umask 077 && printf '%s\n' "${PRIV_KEY:?PRIV_KEY not set}" > "$keyfile" )
}
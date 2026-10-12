#!/bin/sh
# Container entrypoint for the AG Learning Platform Demo.
#
# When the container starts as root it fixes ownership of the persistent data
# directory (required for volumes created by earlier versions) and then drops
# privileges to the unprivileged "app" user before running the application.
# If the container already starts as a non-root user, the command runs as-is.
set -eu

if [ "$(id -u)" = "0" ]; then
    mkdir -p /app/data
    chown -R app:app /app/data
    exec setpriv --reuid=app --regid=app --clear-groups -- "$@"
fi

exec "$@"

#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

set -a
source .env
set +a


if [ ! -d "backups" ]; then
    echo "ERROR: no backups dir" >&2
    exit 1
fi

if [ $(ls -t "backups" 2>/dev/null | wc -l) -eq 0 ]; then
    echo "ERROR: no backups in dir" >&2
    exit 1
fi

backup="backups/$(ls -t "backups/" | head -n 1)"

zcat "$backup" | docker exec -i pg_restore_test psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" --set=ON_ERROR_STOP=1;

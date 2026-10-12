#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "=======$(date '+%F_%H-%M-%S')======="
echo "starting backup.sh"

if ! ./backup.sh; then
    echo "ERROR: backup.sh is failed" >&2
    exit 1
else
    echo "successfully make backup"
fi

if ! ./verify_backup.sh; then
    echo "ERROR: verify_backup.sh is failed" >&2
    exit 1
fi

echo "removing old backups"


find backups -type f -name 'pg_data_backup_*.sql.gz' -mtime +7 -print -delete

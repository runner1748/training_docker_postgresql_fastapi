#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
#export secrets
set -a
source .env
set +a

#make backups dir if not exists
if [ ! -d "backups" ]; then 
	mkdir backups && echo "successfully create backups dir"
fi

status=$(docker inspect -f '{{.State.Running}}' container_postgres_db)

if [ "$status" != "true" ]; then
	echo "ERROR: container is offline" >&2
	exit 1
fi

backup_file="backups/pg_data_backup_$(date '+%F_%H-%M-%S').sql.gz"
docker exec container_postgres_db pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$backup_file"

echo "successfully make backup: $backup_file"
du -h "$backup_file"

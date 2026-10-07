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

#copy data
docker exec container_postgres_db pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > backups/pg_data_backup_$(date '+%F_%H-%M-%S').sql.gz

echo "successfully make backup"

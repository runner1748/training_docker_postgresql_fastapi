#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

set -a
source .env
set +a

cleanup() {
    echo "cleanup starting"
    
    if [ $(docker ps -a -q -f name=^/pg_restore_test$) ]; then
        echo "deleting the pg_restore_test container"
        docker rm -f pg_restore_test >/dev/null 2>&1
    fi
    echo "cleanup is done"
}

trap cleanup EXIT

if [ ! -d "backups" ]; then
    echo "ERROR: no backups dir" >&2
    exit 1
fi

if [ $(ls -t "backups" 2>/dev/null | wc -l) -eq 0 ]; then
    echo "ERROR: no backups in dir" >&2
    exit 1
fi

if [ $(docker ps -a -q -f name=^/pg_restore_test$) ]; then
    echo "removing pg_restore_test container"
    docker rm -f pg_restore_test
fi


docker run -d \
  --name pg_restore_test \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_DB="$POSTGRES_DB" \
  -e POSTGRES_PASSWORD=123456 \
  postgres:17 

counter=0
until docker exec -i pg_restore_test psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" >/dev/null 2>&1; do
    echo -n "."
    sleep 1
    ((counter+=1))

    if [ "$counter" -eq 15 ]; then
        echo "ERROR: db did't start within 15 seconds" >&2
        exit 1
    fi
done




backup="backups/$(ls -t "backups/" | head -n 1)"

zcat "$backup" | docker exec -i pg_restore_test psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" --set=ON_ERROR_STOP=1;

rows_in_db=$(docker exec -i pg_restore_test psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "SELECT count(*) FROM tasks;")


if [ "$rows_in_db" -gt 0 ]; then
    echo "OK: "$rows_in_db" rows restored"
else
    echo "no data in db" >&2
    exit 1
fi
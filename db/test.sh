#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
container="food-check-$$"
log_dir="$(mktemp -d /tmp/food-check.XXXXXX)"
cleanup() { docker rm -f "$container" >/dev/null; }
trap cleanup EXIT
image='postgres:17-bookworm@sha256:665dc7b37ac52a17e298511414c21d23ffa4e6a6ef6225b3e5d59c7afb35e994'
docker run -d --name "$container" -e POSTGRES_PASSWORD=foodexpress_local -e POSTGRES_DB=foodexpress "$image" >/dev/null
for attempt in {1..30}; do
    if docker exec "$container" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
    sleep 1
done
docker exec "$container" pg_isready -h 127.0.0.1 -U postgres
docker cp db "$container":/tmp/db
docker exec "$container" psql -X -U postgres -d foodexpress -v ON_ERROR_STOP=1 -f /tmp/db/bootstrap.sql -f /tmp/db/install.sql > "$log_dir/install.log" 2>&1
check() {
    local database="$1" log="$2"
    if ! docker exec -e PGPASSWORD=NetoSQL2025 "$container" psql -X -h 127.0.0.1 -U inspector -d "$database" -f /tmp/db/tests/checks.sql > "$log" 2>&1; then
        tail -60 "$log"
        return 1
    fi
}
check foodexpress "$log_dir/checks.log"
docker exec "$container" pg_dump -U postgres -d foodexpress -Fc --schema-only -n sergeev_food --no-owner --no-privileges -f /tmp/foodexpress_sergeev.backup
docker exec "$container" createdb -U postgres food_restore
docker exec "$container" psql -X -U postgres -d food_restore -v ON_ERROR_STOP=1 -f /tmp/db/bootstrap.sql > "$log_dir/restore.log" 2>&1
docker exec "$container" pg_restore -U postgres -d food_restore --exit-on-error --no-owner /tmp/foodexpress_sergeev.backup >> "$log_dir/restore.log" 2>&1
docker exec "$container" psql -X -U postgres -d food_restore -v ON_ERROR_STOP=1 -f /tmp/db/schema/grants.sql >> "$log_dir/restore.log" 2>&1
check food_restore "$log_dir/restored-checks.log"
docker exec "$container" pg_restore -l /tmp/foodexpress_sergeev.backup > "$log_dir/archive.list"
# Архив обновляем только после успешного восстановления и повторных тестов.
docker cp "$container":/tmp/foodexpress_sergeev.backup db/foodexpress_sergeev.backup
printf 'Проверки исходной БД и восстановленного архива пройдены. Логи: %s\n' "$log_dir"

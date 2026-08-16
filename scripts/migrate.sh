#!/usr/bin/env bash
# =============================================================================
# Schema migration runner.
#
# Applies any db/<db>/*.sql that has not been applied yet, tracked in a
# schema_migrations table per database. Safe to run repeatedly.
#
# Not every schema file is idempotent, which is exactly why applied files are
# recorded rather than re-run: re-applying 001_schema.sql would fail on the
# first CREATE TABLE and, worse, could duplicate seed rows.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
set -a; source .env; set +a

psql_db() {  # psql_db <database> [args...]
    local db="$1"; shift
    docker exec -i -e PGPASSWORD="$HIS_DB_ADMIN_PASSWORD" his-db-external \
        psql -v ON_ERROR_STOP=1 -U "$HIS_DB_ADMIN_USER" -d "$db" "$@"
}

migrate() {  # migrate <database> <dir> <baseline-table> <baseline-file>
    local db="$1" dir="$2" baseline_table="$3" baseline_file="$4"

    psql_db "$db" -q -c "
        CREATE TABLE IF NOT EXISTS public.schema_migrations (
            filename   text PRIMARY KEY,
            applied_at timestamptz NOT NULL DEFAULT now()
        );" >/dev/null

    # Baseline: a database provisioned before this runner existed already has
    # the first schema file applied, it just was never recorded. Detect that by
    # the presence of a table that file creates, and record it rather than
    # trying to apply it again.
    local recorded
    recorded=$(psql_db "$db" -tAX -c "SELECT count(*) FROM public.schema_migrations;" | tr -d '[:space:]')
    if [[ "$recorded" == "0" ]]; then
        local exists
        exists=$(psql_db "$db" -tAX -c "SELECT to_regclass('$baseline_table') IS NOT NULL;" | tr -d '[:space:]')
        if [[ "$exists" == "t" ]]; then
            echo "    $db: baselining $baseline_file (already present)"
            psql_db "$db" -q -c \
                "INSERT INTO public.schema_migrations (filename) VALUES ('$baseline_file');" >/dev/null
        fi
    fi

    local applied=0
    for f in "$dir"/*.sql; do
        [[ -e "$f" ]] || continue
        local base; base=$(basename "$f")
        local seen
        seen=$(psql_db "$db" -tAX -c \
            "SELECT count(*) FROM public.schema_migrations WHERE filename = '$base';" | tr -d '[:space:]')
        if [[ "$seen" != "0" ]]; then
            echo "    $db: $base (already applied)"
            continue
        fi
        echo "    $db: applying $base"
        psql_db "$db" -q < "$f" >/dev/null
        psql_db "$db" -q -c "INSERT INTO public.schema_migrations (filename) VALUES ('$base');" >/dev/null
        applied=$((applied + 1))
    done
    echo "    $db: $applied new migration(s)"
}

echo "==> Migrating"
migrate "$HIS_DB_NAME"    db/his    "his.patients"           "001_schema.sql"
migrate "$BRIDGE_DB_NAME" db/bridge "bridge.fhir_resources"  "001_schema.sql"
echo "==> Done"

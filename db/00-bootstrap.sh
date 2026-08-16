#!/bin/bash
# =============================================================================
# Bootstraps the "external" HIS database server.
#
# One server, two databases with separate owners: the HIS microservice and the
# bridge each own their data and hold no credentials for the other's database.
# =============================================================================
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    CREATE ROLE ${HIS_DB_USER} LOGIN PASSWORD '${HIS_DB_PASSWORD}';
    CREATE ROLE ${BRIDGE_DB_USER} LOGIN PASSWORD '${BRIDGE_DB_PASSWORD}';

    CREATE DATABASE ${HIS_DB_NAME} OWNER ${HIS_DB_USER};
    CREATE DATABASE ${BRIDGE_DB_NAME} OWNER ${BRIDGE_DB_USER};

    REVOKE ALL ON DATABASE ${HIS_DB_NAME}    FROM PUBLIC;
    REVOKE ALL ON DATABASE ${BRIDGE_DB_NAME} FROM PUBLIC;
    GRANT CONNECT ON DATABASE ${HIS_DB_NAME}    TO ${HIS_DB_USER};
    GRANT CONNECT ON DATABASE ${BRIDGE_DB_NAME} TO ${BRIDGE_DB_USER};
SQL

# Every *.sql in the directory, in filename order, so numbered migrations added
# later are applied on a fresh database without editing this script. An existing
# database needs them applied explicitly — see `make migrate`.
apply_all() {
    local db="$1" dir="$2"
    for f in "$dir"/*.sql; do
        [[ -e "$f" ]] || continue
        echo "[bootstrap] $db <- $(basename "$f")"
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" -f "$f"
    done
}

apply_all "${HIS_DB_NAME}"    /schema/his
apply_all "${BRIDGE_DB_NAME}" /schema/bridge

echo "[bootstrap] done"

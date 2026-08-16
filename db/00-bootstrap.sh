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

echo "[bootstrap] applying HIS schema to ${HIS_DB_NAME}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${HIS_DB_NAME}" \
    -f /schema/his/001_schema.sql

echo "[bootstrap] applying bridge schema to ${BRIDGE_DB_NAME}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${BRIDGE_DB_NAME}" \
    -f /schema/bridge/001_schema.sql

echo "[bootstrap] done"

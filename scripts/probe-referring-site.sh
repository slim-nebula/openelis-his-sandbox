#!/usr/bin/env bash
# Does OpenELIS really auto-create a referring Organization from Task.location?
#
# Proves (or disproves) the bytecode reading in FhirApiWorkFlowServiceImpl:
#   Location on the Task  ->  organization row named from Location.name,
#   keyed on the Location id, linked to the "referring clinic" type.
#
# Touches NOTHING in OpenELIS. The only writes are to the bridge's own FHIR
# store, which is ours.
set -euo pipefail
ROOT=/Users/slimaidi/Documents/openelis
cd "$ROOT"
set -a; . ./.env; set +a

SITE_NAME="${SITE_NAME:-Obygaine Dermatology}"
LOC_UUID=$(python3 -c 'import uuid;print(uuid.uuid4())')
PATIENT=e0713979-8a2e-4545-89f0-a885ad6b0fa7      # Ibrahim Diallo
BPW=$(docker exec bridge sh -c 'echo "$BRIDGE_DB_CONNECTION"' | sed -n 's/.*Password=\([^;]*\).*/\1/p')
bq() { docker exec -e PGPASSWORD="$BPW" -i his-db-external psql -U bridge_app -d bridge_sandbox -tAc "$1"; }
oq() { docker exec -i openelis-db-external psql -U clinlims -d clinlims -tAc "$1"; }

echo "==> Referring site under test: $SITE_NAME"
echo "    Location id: $LOC_UUID"

echo "==> 1. Publishing the Location into the bridge FHIR store"
docker exec -e PGPASSWORD="$BPW" -i his-db-external psql -U bridge_app -d bridge_sandbox >/dev/null <<SQL
INSERT INTO bridge.fhir_resources (resource_type, resource_id, content)
VALUES ('Location', '$LOC_UUID', jsonb_build_object(
    'resourceType','Location', 'id','$LOC_UUID',
    'status','active', 'name', \$\$${SITE_NAME}\$\$));
SQL
echo "    stored"

echo "==> 2. Placing an order"
TOKEN=$(scripts/mint-token.sh --quiet --user 1 --name locationtest \
        ${LAB_ORDER_GROUP:+--groups "$LAB_ORDER_GROUP"})
RESP=$(curl -fsS -X POST "http://localhost:${EDGE_HTTP_PORT}/api/lab-orders" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"patientId\":\"$PATIENT\",\"testCode\":\"10351-5|DBS\",\"facilityCode\":\"FAC-001\"}")
ORDER_NUMBER=$(python3 -c "import sys,json;print(json.load(sys.stdin)['orderNumber'])" <<<"$RESP")
echo "    $ORDER_NUMBER"

echo "==> 3. Waiting for the bridge to publish the Task, then attaching the Location"
TASK_ID=""
for i in $(seq 1 40); do
  TASK_ID=$(bq "SELECT resource_id FROM bridge.fhir_resources
                 WHERE resource_type='Task'
                   AND content->'basedOn'->0->>'reference'='ServiceRequest/$ORDER_NUMBER';" | tr -d '[:space:]')
  [[ -n "$TASK_ID" ]] && break
  sleep 0.5
done
[[ -n "$TASK_ID" ]] || { echo "    FAILED: the bridge never published a Task"; exit 1; }

bq "UPDATE bridge.fhir_resources
       SET content = jsonb_set(content,'{location}',
                               jsonb_build_object('reference','Location/$LOC_UUID'))
     WHERE resource_type='Task' AND resource_id='$TASK_ID';" >/dev/null
STATUS=$(bq "SELECT content->>'status' FROM bridge.fhir_resources
              WHERE resource_type='Task' AND resource_id='$TASK_ID';" | tr -d '[:space:]')
echo "    Task $TASK_ID patched, status=$STATUS"
if [[ "$STATUS" != "requested" ]]; then
  echo "    ABORT: OpenELIS polled before the patch landed. Re-run."
  exit 2
fi

echo "==> 4. Waiting for OpenELIS to poll (up to 3 minutes)"
for i in $(seq 1 36); do
  S=$(bq "SELECT content->>'status' FROM bridge.fhir_resources
           WHERE resource_type='Task' AND resource_id='$TASK_ID';" | tr -d '[:space:]')
  if [[ "$S" != "requested" ]]; then echo "    imported after ~$((i*5))s, Task is now '$S'"; break; fi
  sleep 5
done

echo "==> 5. Did an organization appear?"
echo "--- organization rows carrying that Location uuid ---"
oq "SELECT o.id, o.name, coalesce(o.code,'(null)'), o.fhir_uuid, ot.org_type_id
      FROM organization o
      LEFT JOIN organization_organization_type ot ON ot.org_id=o.id
     WHERE o.fhir_uuid='$LOC_UUID';"
echo "--- all organizations ---"
oq "SELECT o.id, o.name, ot.org_type_id FROM organization o
      LEFT JOIN organization_organization_type ot ON ot.org_id=o.id ORDER BY o.id;"
echo "--- did the order itself import? ---"
oq "SELECT external_id, status_id FROM electronic_order WHERE external_id='$ORDER_NUMBER';"
echo
echo "LOC_UUID=$LOC_UUID  ORDER=$ORDER_NUMBER  TASK=$TASK_ID"

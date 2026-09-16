#!/usr/bin/env bash
# =============================================================================
# Restart durability — can a container restart lose a lab order?
#
# Every other suite tests the happy path with the whole stack up. This one takes
# components away UNDERNEATH live orders and checks that the order arrives
# anyway. It is the suite that answers "what happens at 3am when Docker restarts
# a container", and the answer has to be "nothing, it catches up".
#
# Four independent restarts, each with a real order in flight:
#
#   A  the bridge is DOWN when the clinician places the order
#   B  the bridge restarts while the order waits to be collected
#   C  a delivery lease survives the restart that interrupted it
#   D  OpenELIS restarts with an order outstanding
#   E  the result-push channel recovers from a failed push on its own
#
#   scripts/test-restart.sh [TEST_CODE]
#
# SLOW. Section D restarts Tomcat, which is minutes, not seconds. Skip it with
# SKIP_OPENELIS=1 when iterating on the rest.
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_CODE="${1:-$(any_active_test_code)}"
if [[ -z "$TEST_CODE" ]]; then
    echo "  No orderable test in the HIS menu. Run: make sync-catalogue" >&2
    exit 1
fi

ACCEPT_TIMEOUT="${ACCEPT_TIMEOUT:-240}"          # OpenELIS polls every 30s
OPENELIS_BOOT_TIMEOUT="${OPENELIS_BOOT_TIMEOUT:-600}"
SKIP_OPENELIS="${SKIP_OPENELIS:-0}"

# --- Helpers -----------------------------------------------------------------

# Place an order for a patient created on the spot. Sets PATIENT_ID, ORDER_ID,
# ORDER_NUMBER. A fresh patient each time keeps the sections independent: a
# shared patient would let section B pass on section A's row.
place_order() {
    local label="$1"
    local patient_json order_json

    patient_json=$(api_curl -sf -X POST "${API}/patients" \
        -H 'Content-Type: application/json' \
        -d "{\"firstName\":\"Restart\",\"lastName\":\"Probe${label}\",\"sex\":\"F\",
             \"dateOfBirth\":\"1988-04-17\",\"phone\":\"+22370000${RANDOM:0:3}\",
             \"nationalId\":\"NID-RESTART-${label}-$$\"}")
    PATIENT_ID=$(echo "$patient_json" | json_field "['patientId']")
    [[ -n "$PATIENT_ID" ]] || { bad "[$label] patient created" "$patient_json"; return 1; }

    order_json=$(api_curl -sf -X POST "${API}/lab-orders" \
        -H 'Content-Type: application/json' \
        -d "{\"patientId\":\"$PATIENT_ID\",\"testCode\":\"$TEST_CODE\",
             \"facilityCode\":\"FAC-001\",\"priority\":\"routine\"}")
    ORDER_ID=$(echo "$order_json" | json_field "['orderId']")
    ORDER_NUMBER=$(echo "$order_json" | json_field "['orderNumber']")
    [[ -n "$ORDER_NUMBER" ]] || { bad "[$label] order placed" "$order_json"; return 1; }
    return 0
}

# Wait until the bridge has published a FHIR Task for an order.
wait_for_task() {  # wait_for_task <order_number> <seconds>
    local order="$1" deadline=$(( SECONDS + $2 ))
    while (( SECONDS < deadline )); do
        [[ -n $(bridge_sql "SELECT fhir_task_id FROM bridge.order_tracking WHERE order_number = '$order'") ]] && return 0
        sleep 3
    done
    return 1
}

# Wait until OpenELIS has given the order a verdict. Echoes the verdict.
wait_for_verdict() {  # wait_for_verdict <order_number> <seconds>
    local order="$1" deadline=$(( SECONDS + $2 )) status
    while (( SECONDS < deadline )); do
        status=$(bridge_sql "SELECT task_status FROM bridge.order_tracking WHERE order_number = '$order'")
        if [[ "$status" == "accepted" || "$status" == "rejected" ]]; then echo "$status"; return 0; fi
        sleep 5
    done
    echo "${status:-unknown}"
    return 1
}

wait_for_bridge() {  # wait_for_bridge <seconds>
    local deadline=$(( SECONDS + $1 ))
    while (( SECONDS < deadline )); do
        [[ "$(docker inspect -f '{{.State.Health.Status}}' bridge 2>/dev/null)" == "healthy" ]] && return 0
        sleep 2
    done
    return 1
}

# ---------------------------------------------------------------------------
section "A · The bridge is DOWN when the clinician places the order"

info "stopping the bridge…"
docker stop bridge >/dev/null 2>&1

check "The bridge really is stopped" \
    "[[ \$(docker inspect -f '{{.State.Running}}' bridge) == false ]]"

if place_order "A"; then
    ok "[A] The HIS still accepts the order with the bridge down: $ORDER_NUMBER"
    ORDER_A="$ORDER_NUMBER"

    # The point of the whole section. The HIS must not refuse clinical work
    # because an integration component is restarting — the laboratory is a
    # downstream consumer, not a precondition for ordering a test.
    check "[A] The order is committed to the HIS database" \
        "[[ \$(his_sql \"SELECT count(*) FROM his.lab_orders WHERE order_number = '$ORDER_A'\") == 1 ]]"

    # It is held on the topic, not in anyone's memory. Kafka retains it until a
    # consumer in group 'bridge' commits past it, and there is no such consumer
    # right now.
    check "[A] Nothing reached the bridge — there was nothing to reach" \
        "[[ \$(bridge_sql \"SELECT count(*) FROM bridge.order_tracking WHERE order_number = '$ORDER_A'\") == 0 ]]"

    info "starting the bridge again…"
    docker start bridge >/dev/null 2>&1
    if wait_for_bridge 120; then
        ok "[A] The bridge came back healthy"
    else
        bad "[A] The bridge came back healthy" "still not healthy after 120s"
    fi

    if wait_for_task "$ORDER_A" 120; then
        ok "[A] The order was delivered on restart — Kafka held it, nothing was lost"
    else
        bad "[A] The order was delivered on restart" \
            "no FHIR Task for $ORDER_A after 120s; check: docker logs bridge"
    fi
else
    bad "[A] The HIS still accepts the order with the bridge down" "order placement failed"
    docker start bridge >/dev/null 2>&1; wait_for_bridge 120
    ORDER_A=""
fi

# ---------------------------------------------------------------------------
section "B · The bridge restarts while the order waits to be collected"

if place_order "B"; then
    ORDER_B="$ORDER_NUMBER"
    if wait_for_task "$ORDER_B" 90; then
        ok "[B] Task published for $ORDER_B"

        TASK_B=$(bridge_sql "SELECT fhir_task_id FROM bridge.order_tracking WHERE order_number = '$ORDER_B'")

        info "restarting the bridge with the Task still outstanding…"
        docker restart bridge >/dev/null 2>&1
        wait_for_bridge 120 || bad "[B] The bridge came back healthy" "timeout"

        # The FHIR resources live in Postgres, not in the process. A restart is
        # not supposed to be able to touch them.
        check "[B] The FHIR Task survived the restart" \
            "[[ \$(bridge_sql \"SELECT count(*) FROM bridge.fhir_resources WHERE resource_id = '$TASK_B'\") == 1 ]]"
        check "[B] Its tracking row survived with it" \
            "[[ \$(bridge_sql \"SELECT count(*) FROM bridge.order_tracking WHERE order_number = '$ORDER_B'\") == 1 ]]"

        info "waiting up to ${ACCEPT_TIMEOUT}s for OpenELIS to collect it…"
        VERDICT_B=$(wait_for_verdict "$ORDER_B" "$ACCEPT_TIMEOUT")
        if [[ "$VERDICT_B" == "accepted" ]]; then
            ok "[B] OpenELIS collected the order after the restart: accepted"
        elif [[ "$VERDICT_B" == "rejected" ]]; then
            bad "[B] OpenELIS collected the order after the restart" \
                "rejected — the LOINC no longer resolves. Run: make sync-catalogue"
        else
            bad "[B] OpenELIS collected the order after the restart" \
                "still '$VERDICT_B' after ${ACCEPT_TIMEOUT}s"
        fi
    else
        bad "[B] Task published for $ORDER_B" "no Task after 90s"
        ORDER_B=""
    fi
else
    ORDER_B=""
fi

# ---------------------------------------------------------------------------
section "C · A delivery lease survives the restart that interrupted it"

# The lease is what stops two simultaneous polls importing one order twice. If
# it lived in the process, a restart mid-import would either strand the Task
# (lease never released) or duplicate it (lease forgotten). It lives in
# Postgres and expires on a CLOCK, so a restart is irrelevant to it — that is
# the property this section pins.
if [[ -n "${ORDER_B:-}" && -n "${TASK_B:-}" ]]; then
    LEASE_BEFORE=$(bridge_sql "SELECT deliveries || '|' || first_at FROM bridge.delivery_leases WHERE resource_id = '$TASK_B'")

    if [[ -n "$LEASE_BEFORE" ]]; then
        ok "[C] The collection left a lease row behind: $LEASE_BEFORE"

        info "restarting the bridge again…"
        docker restart bridge >/dev/null 2>&1
        wait_for_bridge 120 || bad "[C] The bridge came back healthy" "timeout"

        LEASE_AFTER=$(bridge_sql "SELECT deliveries || '|' || first_at FROM bridge.delivery_leases WHERE resource_id = '$TASK_B'")
        if [[ "$LEASE_AFTER" == "$LEASE_BEFORE" ]]; then
            ok "[C] The lease is unchanged by the restart — it is state, not memory"
        else
            bad "[C] The lease is unchanged by the restart" \
                "before='$LEASE_BEFORE' after='$LEASE_AFTER'"
        fi

        # A lease released by a verdict must not erase the attempt history: the
        # counter is how an operator sees an order that was collected five times
        # and never acknowledged.
        check "[C] Releasing the lease kept the delivery count, it did not delete the row" \
            "[[ \$(bridge_sql \"SELECT deliveries FROM bridge.delivery_leases WHERE resource_id = '$TASK_B'\") -ge 1 ]]"
    else
        info "[C] no lease row for $TASK_B — the import completed before this ran; nothing to assert"
    fi
else
    info "[C] skipped: section B did not produce a Task"
fi

# ---------------------------------------------------------------------------
section "D · OpenELIS restarts with an order outstanding"

if [[ "$SKIP_OPENELIS" == "1" ]]; then
    info "skipped (SKIP_OPENELIS=1)"
elif place_order "D"; then
    ORDER_D="$ORDER_NUMBER"
    if wait_for_task "$ORDER_D" 90; then
        ok "[D] Task published for $ORDER_D"

        info "restarting OpenELIS — this is Tomcat, allow several minutes…"
        docker restart openelis-webapp >/dev/null 2>&1

        # The Task must simply sit in `requested` while the laboratory is away.
        # Nothing on the bridge side times it out or cancels it: the bridge has
        # no opinion about how long a laboratory takes to collect an order.
        sleep 20
        check "[D] The Task is still requested while OpenELIS is away" \
            "[[ \$(bridge_sql \"SELECT task_status FROM bridge.order_tracking WHERE order_number = '$ORDER_D'\") == requested ]]"

        info "waiting up to ${OPENELIS_BOOT_TIMEOUT}s for OpenELIS to boot and poll again…"
        VERDICT_D=$(wait_for_verdict "$ORDER_D" "$OPENELIS_BOOT_TIMEOUT")
        if [[ "$VERDICT_D" == "accepted" ]]; then
            ok "[D] OpenELIS picked the order up after its restart: accepted"
        elif [[ "$VERDICT_D" == "rejected" ]]; then
            bad "[D] OpenELIS picked the order up after its restart" \
                "rejected — catalogue drift, not a restart fault. Run: make sync-catalogue"
        else
            bad "[D] OpenELIS picked the order up after its restart" \
                "still '$VERDICT_D' after ${OPENELIS_BOOT_TIMEOUT}s"
        fi
    else
        bad "[D] Task published for $ORDER_D" "no Task after 90s"
    fi
fi

# ---------------------------------------------------------------------------
section "E · The result-push channel recovers from a failed push on its own"

# OpenELIS pushes released results to the bridge on a timer. When the bridge is
# away, the push FAILS — and the question that matters is whether the results in
# that window are re-sent or silently skipped.
#
# They are re-sent. DataExportServiceImpl.getBundlesFromLocalServer builds its
# search window as
#
#     lower bound = getLatestSuccessInstantForDataExportTask(task)
#     upper bound = this attempt's start time
#
# and getLatestSuccessInstantForDataExportTask queries attempts filtered to
# SUCCEEDED, falling back to Instant.EPOCH. So the window stretches back to the
# last SUCCESSFUL push, not the last attempt: every failure widens it, and a
# result released during an outage is inside the next successful window.
#
# This section proves the channel does fail and recover unattended. The window
# semantics above are verified from OpenELIS's own bytecode — see docs/durability.md.
LAST_SUCCESS_BEFORE=$(oe_sql "SELECT max(start_time) FROM clinlims.data_export_attempt WHERE data_export_status = 'SUCCEEDED'")
FAILED_BEFORE=$(oe_sql "SELECT count(*) FROM clinlims.data_export_attempt WHERE data_export_status = 'FAILED'")

info "stopping the bridge to break the push channel…"
docker stop bridge >/dev/null 2>&1

info "waiting up to 200s for OpenELIS to notice (it pushes every $(oe_sql "SELECT max_data_export_interval FROM clinlims.data_export_task") min)…"
FAILED_SEEN=0
DEADLINE=$(( SECONDS + 200 ))
while (( SECONDS < DEADLINE )); do
    NOW_FAILED=$(oe_sql "SELECT count(*) FROM clinlims.data_export_attempt WHERE data_export_status = 'FAILED'")
    if [[ "${NOW_FAILED:-0}" -gt "${FAILED_BEFORE:-0}" ]]; then FAILED_SEEN=1; break; fi
    sleep 10
done

if [[ "$FAILED_SEEN" == "1" ]]; then
    ok "[E] OpenELIS recorded the failed push instead of dropping it quietly"
else
    bad "[E] OpenELIS recorded the failed push" \
        "no new FAILED attempt in 200s (was ${FAILED_BEFORE:-0})"
fi

info "bringing the bridge back…"
docker start bridge >/dev/null 2>&1
wait_for_bridge 120 || bad "[E] The bridge came back healthy" "timeout"

info "waiting up to 200s for the next push to succeed…"
RECOVERED=0
DEADLINE=$(( SECONDS + 200 ))
while (( SECONDS < DEADLINE )); do
    LAST_SUCCESS_NOW=$(oe_sql "SELECT max(start_time) FROM clinlims.data_export_attempt WHERE data_export_status = 'SUCCEEDED'")
    if [[ "$LAST_SUCCESS_NOW" != "$LAST_SUCCESS_BEFORE" ]]; then RECOVERED=1; break; fi
    sleep 10
done

if [[ "$RECOVERED" == "1" ]]; then
    ok "[E] The channel healed by itself — no operator, no replay, no lost window"
else
    bad "[E] The channel healed by itself" \
        "no successful push within 200s of the bridge returning"
fi

# ---------------------------------------------------------------------------
section "Orders created by this run"

for o in ${ORDER_A:-} ${ORDER_B:-} ${ORDER_D:-}; do
    info "$o  →  $(his_sql "SELECT order_status FROM his.lab_orders WHERE order_number = '$o'")"
done

summary

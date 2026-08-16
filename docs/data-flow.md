# Data flow — full round trip

Every hop below was observed in a live run against OpenELIS Global 2 on the
upstream `develop` images. Endpoint paths, topic names, table names and status
values are the real ones, not illustrative.

---

## 1. The round trip

A single order, from a clinician typing it to the released result appearing
back in the HIS. The five phases are marked; phase D is the only one a human
drives.

```mermaid
sequenceDiagram
    autonumber
    actor Doc as Clinician
    participant FE as Frontend<br/>nginx
    participant PX as Edge proxy<br/>:8090
    participant KG as Kong<br/>gateway
    participant API as his-api<br/>Patient + Lab Order
    participant HDB as his_sandbox<br/>external DB
    participant K as Kafka
    participant BR as bridge<br/>FHIR R4 server
    participant BDB as bridge_sandbox<br/>external DB
    participant OE as OpenELIS<br/>webapp
    participant ODB as clinlims<br/>external DB
    actor Tech as Lab technician

    rect rgb(232, 240, 252)
    Note over Doc, HDB: A · Order capture — synchronous, through the edge
    Doc->>FE: Select patient, choose test
    FE->>PX: POST /api/lab-orders
    PX->>KG: proxy_pass, X-Correlation-ID
    KG->>API: POST /lab-orders
    Note right of KG: correlation-id plugin mints<br/>the id if absent
    API->>HDB: SELECT test_catalogue WHERE test_code
    API->>HDB: SELECT patient exists
    Note right of API: Unknown test or patient → 400,<br/>nothing is written
    API->>HDB: INSERT lab_orders status=CREATED<br/>+ lab_order_events ORDER_CREATED
    API->>K: publish lab.order.created<br/>key=orderId, header X-Correlation-ID
    Note right of API: Publish failure → order marked FAILED,<br/>caller gets 502, never a silent success
    API-->>Doc: 201 order_number LAB-YYYYMMDD-XXXXXXXX
    end

    rect rgb(234, 245, 236)
    Note over K, BDB: B · Bridge maps the order into FHIR
    K->>BR: consume lab.order.created
    BR->>BDB: INSERT processed_events (claim eventId)
    Note right of BR: Already claimed → duplicate, ignored
    BR->>API: GET /internal/lab-orders/{orderId}
    Note over BR, API: Direct on the sandbox network.<br/>Kong does not route /internal/*
    API->>HDB: SELECT order + catalogue + patient
    API-->>BR: order payload incl. LOINC + specimen type
    BR->>BR: Map to Patient, Practitioner ×2,<br/>Specimen, ServiceRequest, Task
    Note right of BR: Resource ids are UUIDv5 of the order id,<br/>so a replay updates instead of duplicating
    BR->>BDB: upsert fhir_resources<br/>+ order_tracking task_status=requested
    BR->>K: publish lab.order.sent SENT_TO_LIS
    K->>API: consume
    API->>HDB: UPDATE order_status=SENT_TO_LIS
    end

    rect rgb(252, 245, 230)
    Note over OE, ODB: C · OpenELIS pulls the order — it is never pushed
    loop every OE_REMOTE_POLL_FREQUENCY (30s)
        OE->>BR: GET /fhir/Task?status=requested&owner=Practitioner/{uuid}
    end
    BR-->>OE: searchset Bundle, 1 match
    OE->>BR: GET /fhir/ServiceRequest/{id} — from Task.basedOn
    OE->>BR: GET /fhir/Patient/{id} — from Task.for
    OE->>BR: GET /fhir/Practitioner/{id} — from ServiceRequest.requester
    OE->>BR: GET /fhir/Specimen/{id} — from ServiceRequest.specimen
    OE->>OE: TaskInterpreter matches<br/>ServiceRequest.code LOINC coding
    OE->>ODB: SELECT test WHERE loinc = code
    Note right of ODB: No match → Task rejected.<br/>This is what `make provision` prevents
    OE->>ODB: INSERT electronic_order<br/>external_id = order_number
    OE->>BR: PUT /fhir/Task/{id} status=accepted
    BR->>BDB: UPDATE order_tracking task_status=accepted
    BR->>K: publish lab.order.sent ACCEPTED_BY_LIS
    K->>API: consume
    API->>HDB: UPDATE order_status=ACCEPTED_BY_LIS
    end

    rect rgb(245, 236, 246)
    Note over Tech, ODB: D · Laboratory workflow — the manual step
    Tech->>OE: Accession the incoming order
    Tech->>OE: Enter result value
    Tech->>OE: Validate and release
    OE->>ODB: analysis released, result recorded
    OE->>OE: FhirTransformService builds<br/>Observation + DiagnosticReport
    end

    rect rgb(234, 245, 236)
    Note over OE, Doc: E · Result returns through the bridge
    OE->>BR: PUT /fhir/ServiceRequest/{analysisId}
    OE->>BR: PUT /fhir/Observation/{id}
    OE->>BR: PUT /fhir/DiagnosticReport/{id} status=final
    Note over OE, BR: rest-hook Subscription, plus a bundle<br/>push every OE_SUBSCRIBER_BACKUP_INTERVAL
    BR->>BDB: upsert received_resources, processed=false
    loop every 10s
        BR->>BDB: scan unprocessed DiagnosticReport
    end
    BR->>BR: Correlate: DiagnosticReport.basedOn →<br/>analysis ServiceRequest.basedOn → our ServiceRequest
    Note right of BR: Chain not landed yet → left for the<br/>next sweep, dead-lettered after 15 min
    BR->>BDB: INSERT forwarded_results (claim by DR ref)
    BR->>K: publish lab.result.released
    Note right of BR: Only final / amended / corrected.<br/>Preliminary values stay in the lab
    K->>API: consume
    API->>HDB: upsert lab_results_summary<br/>ON CONFLICT (openelis_result_ref)
    API->>HDB: UPDATE order_status=RESULT_AVAILABLE<br/>+ INSERT integration_mappings
    Doc->>FE: View patient
    FE->>KG: GET /api/patients/{id}/results
    KG->>API: GET /patients/{id}/results
    API-->>Doc: value, unit, interpretation,<br/>openelis_result_ref
    end
```

---

## 2. Where the data lives, and what may talk to what

Network membership *is* the boundary. The bridge is the only container on both
`sandbox` and `integration`, which makes it the only path between the two
systems. No application container shares a network with a database it does not
own.

```mermaid
flowchart LR
    Doc([Clinician]):::actor
    Tech([Lab technician]):::actor

    subgraph SB["oe-sandbox-net · HIS platform"]
        direction TB
        FE[Frontend]
        PX[Edge proxy<br/>:8090]
        KG[Kong gateway]
        API[his-api]
        K[(Kafka<br/>5 topics + DLQs)]
        RD[(Redis<br/>provisioned, unused)]
        BR[bridge]
    end

    subgraph IN["oe-integration-net · the entire HIS ↔ LIS surface"]
        direction TB
        BR2[bridge<br/>FHIR R4 endpoint]
        OE[OpenELIS webapp]
    end

    subgraph OEN["oe-internal-net · OpenELIS internals"]
        direction TB
        OE2[OpenELIS webapp]
        HAPI[HAPI FHIR store]
        OFE[OpenELIS UI]
        OPX[OpenELIS proxy]
    end

    subgraph DT["oe-data-net · external database servers"]
        direction TB
        HDB[(his_sandbox<br/>owner: his_app)]
        BDB[(bridge_sandbox<br/>owner: bridge_app)]
        ODB[(clinlims<br/>owner: clinlims)]
    end

    Doc --> PX
    PX --> FE
    PX --> KG
    KG --> API
    API <--> K
    K <--> BR
    BR -. "GET /internal/lab-orders/{id}<br/>direct, never via Kong" .-> API
    BR === BR2
    BR2 <--> OE
    OE === OE2
    OE2 --> HAPI
    Tech --> OPX
    OPX --> OFE
    OPX --> OE2

    API --> HDB
    BR --> BDB
    OE2 --> ODB
    HAPI --> ODB

    classDef actor fill:#fff,stroke:#555,stroke-dasharray:3 3
    classDef db fill:#f4f4f8,stroke:#666
    class HDB,BDB,ODB,K,RD db
```

Three databases, three owners, no shared credentials — verified: the bridge's
role is refused `CONNECT` on `his_sandbox`, and OpenELIS holds no HIS
credentials at all.

---

## 3. Order status lifecycle

Each transition is driven by a specific event, so a stuck order tells you
exactly which hop failed.

```mermaid
stateDiagram-v2
    [*] --> CREATED: POST /lab-orders<br/>row committed

    CREATED --> SENT_TO_LIS: bridge published the FHIR Task<br/>lab.order.sent
    CREATED --> FAILED: Kafka unreachable<br/>502 to the caller

    SENT_TO_LIS --> ACCEPTED_BY_LIS: OpenELIS PUT Task status=accepted
    SENT_TO_LIS --> REJECTED_BY_LIS: OpenELIS PUT Task status=rejected<br/>lab.order.failed
    SENT_TO_LIS --> SENT_TO_LIS: LIS offline — Task stays<br/>requested until it returns

    ACCEPTED_BY_LIS --> RESULT_AVAILABLE: DiagnosticReport correlated<br/>lab.result.released

    RESULT_AVAILABLE --> RESULT_AVAILABLE: amended or corrected report<br/>upsert, never a duplicate row

    REJECTED_BY_LIS --> [*]
    FAILED --> [*]
    RESULT_AVAILABLE --> [*]

    note right of REJECTED_BY_LIS
        Almost always test identity:
        no OpenELIS test carries
        that LOINC code.
        OpenELIS keeps the order as
        NonConforming, queues no work.
        Verified by make rejection
    end note
```

---

## 4. Failure and recovery paths

What happens when a hop breaks, and how the data gets through anyway.

```mermaid
flowchart TD
    A[lab.order.created consumed] --> B{Payload parses?}
    B -- no --> DLQ[["lab.order.created.dlq<br/>+ bridge.dead_letters"]]:::bad
    DLQ --> CM[Offset committed<br/>partition keeps moving]:::ok
    B -- yes --> C{eventId already claimed?}
    C -- yes --> SKIP[Ignored as duplicate]:::ok
    C -- no --> D{HIS order fetch}
    D -- fails --> R[Exponential backoff<br/>up to BRIDGE_MAX_RETRIES]
    R --> D
    R -- exhausted --> DL2[[dead_letters<br/>+ lab.order.failed]]:::bad
    D -- ok --> E{LOINC mapping present?}
    E -- no --> DL2
    E -- yes --> F[Publish FHIR Task]:::ok

    F --> G{OpenELIS reachable?}
    G -- no --> H[Task stays requested<br/>imported on the next poll]:::ok
    G -- yes --> I{Test matches the LOINC?}
    I -- no --> J[Task rejected<br/>order REJECTED_BY_LIS]:::bad
    I -- yes --> K[electronic_order created]:::ok

    K --> L[Result released]
    L --> M{ServiceRequest chain landed?}
    M -- not yet --> N[Left unprocessed<br/>retried every 10s]
    N --> M
    N -- 15 min --> DL3[[dead_letters<br/>+ lab.result.failed]]:::bad
    M -- yes --> O{Already forwarded?}
    O -- yes --> SKIP2[Skipped, idempotent]:::ok
    O -- no --> P[lab.result.released<br/>→ HIS projection]:::ok

    classDef ok fill:#e4f4ea,stroke:#147a3d
    classDef bad fill:#fdeceb,stroke:#b42318
```

Every arrow above is exercised by `make negative`, except the two dead-letter
timeouts, which are time-based.

---

## 5. The two identifiers that hold it together

Correlating a released result back to a HIS order is the subtlest part of the
design, because OpenELIS renames nothing but re-parents everything.

```mermaid
flowchart LR
    subgraph HIS["HIS side"]
        ORD["lab_orders<br/>order_number = LAB-20260808-4803B6C9"]
    end

    subgraph BRG["bridge — published"]
        SR1["ServiceRequest/{orderId}<br/>identifier = order_number"]
        TSK["Task/{uuidv5}<br/>owner = Practitioner/{lab uuid}"]
    end

    subgraph OES["OpenELIS — its own copies"]
        SRC["ServiceRequest/{orderId}<br/>same id, plus identifier<br/>system = http://bridge:8080/fhir"]
        SR2["ServiceRequest/{analysisId}<br/>basedOn → ServiceRequest/{orderId}"]
        DR["DiagnosticReport/{id}<br/>basedOn → ServiceRequest/{analysisId}"]
        OBS["Observation/{id}<br/>valueQuantity, interpretation"]
    end

    ORD --> SR1
    SR1 --> TSK
    TSK -.->|"imported"| SRC
    SRC --> SR2
    SR2 --> DR
    DR -->|result| OBS

    DR -.->|"correlation walk"| SR2
    SR2 -.->|"basedOn"| SRC
    SRC -.->|"id match → order_tracking"| ORD
```

Two facts make the walk reliable, both confirmed against resources OpenELIS
actually pushed back:

- OpenELIS **preserves our `ServiceRequest` id** when it imports the order, so
  the parent reference resolves directly against `bridge.order_tracking`.
- It also stamps its own identifier on that copy
  (`system = http://bridge:8080/fhir`) **and keeps our order-number
  identifier**, giving a second, independent way to match if the id chain ever
  breaks.

The bridge tries the direct id match first, then the parent hop, then the
order-number identifier — see `ResolveOrderAsync` in
[ResultCorrelator.cs](../services/Bridge/ResultCorrelator.cs).

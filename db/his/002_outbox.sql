-- =============================================================================
-- Transactional outbox
--
-- Removes the dual write on order creation. Previously the order row was
-- committed and the Kafka publish happened afterwards, so a crash in between
-- left an order that no one would ever dispatch — visibly fine, silently never
-- sent to the laboratory.
--
-- Now the event is written into this table inside the SAME transaction as the
-- order, and a relay publishes from here. One commit decides both, so the
-- system can crash anywhere and still converge: either the order and its event
-- both exist, or neither does.
--
-- Idempotent so it can be applied to an existing database.
-- =============================================================================

SET search_path TO his;

CREATE TABLE IF NOT EXISTS outbox (
    outbox_id      bigserial PRIMARY KEY,
    event_id       uuid         NOT NULL UNIQUE,
    aggregate_type varchar(32)  NOT NULL,
    aggregate_id   uuid         NOT NULL,
    topic          varchar(128) NOT NULL,
    partition_key  varchar(128) NOT NULL,
    payload        jsonb        NOT NULL,
    correlation_id varchar(64),
    created_at     timestamptz  NOT NULL DEFAULT now(),
    published_at   timestamptz,
    attempts       integer      NOT NULL DEFAULT 0,
    last_error     text
);

-- The relay's hot path: oldest unpublished first. Partial index, so published
-- rows cost nothing to skip however many accumulate.
CREATE INDEX IF NOT EXISTS ix_outbox_unpublished
    ON outbox (outbox_id) WHERE published_at IS NULL;

-- Supports pruning without scanning live rows.
CREATE INDEX IF NOT EXISTS ix_outbox_published
    ON outbox (published_at) WHERE published_at IS NOT NULL;

COMMENT ON TABLE outbox IS
    'Events written in the same transaction as the aggregate that produced them; drained to Kafka by the outbox relay.';
COMMENT ON COLUMN outbox.partition_key IS
    'Kafka message key. Same key for the same order, so per-order ordering is preserved.';

GRANT ALL ON outbox TO his_app;
GRANT USAGE, SELECT ON SEQUENCE outbox_outbox_id_seq TO his_app;

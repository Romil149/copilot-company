-- DIMENSION 1: EVENT SOURCING (Complete Implementation)
-- Immutable event log with versioning, conflict detection, and data lineage
-- Version: 1.0

\c copilot_company

SET search_path TO events, core, public;

-- ============================================================================
-- ADDITIONAL EVENT LOG TABLES
-- ============================================================================

CREATE TABLE IF NOT EXISTS events.event_subscriptions (
  id BIGSERIAL PRIMARY KEY,
  subscription_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What events to subscribe to
  event_type_pattern VARCHAR(100), -- Supports wildcards: 'Deal*', '*Created'
  aggregate_type entity_type,
  
  -- Who subscribes
  subscriber_name VARCHAR(255) NOT NULL,
  subscriber_type VARCHAR(50), -- 'AGENT', 'SERVICE', 'WEBHOOK'
  subscriber_endpoint VARCHAR(500),
  
  -- Status
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  last_triggered_at TIMESTAMP,
  trigger_count BIGINT DEFAULT 0,
  
  INDEX idx_event_type (event_type_pattern),
  INDEX idx_aggregate_type (aggregate_type),
  INDEX idx_subscriber (subscriber_name),
  INDEX idx_active (is_active)
);

CREATE TABLE IF NOT EXISTS events.event_snapshots (
  id BIGSERIAL PRIMARY KEY,
  snapshot_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What entity
  aggregate_id UUID NOT NULL,
  aggregate_type entity_type NOT NULL,
  
  -- Current state
  state_data JSONB NOT NULL,
  
  -- Versioning
  snapshot_at_version INT NOT NULL,
  last_event_id UUID NOT NULL REFERENCES events.event_log(event_id),
  
  -- Compression
  is_compressed BOOLEAN DEFAULT FALSE,
  compression_ratio DECIMAL(3, 2),
  
  -- Timing
  created_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_aggregate (aggregate_id, aggregate_type),
  INDEX idx_version (snapshot_at_version),
  INDEX idx_created_at (created_at DESC)
);

CREATE TABLE IF NOT EXISTS core.data_lineage (
  id BIGSERIAL PRIMARY KEY,
  lineage_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What value
  entity_id UUID NOT NULL,
  entity_type entity_type NOT NULL,
  field_name VARCHAR(100) NOT NULL,
  current_value TEXT,
  
  -- Where it came from
  source_event_id UUID NOT NULL REFERENCES events.event_log(event_id),
  source_agent_id UUID,
  source_timestamp TIMESTAMP,
  
  -- How it was transformed
  transformation_steps JSONB DEFAULT '[]',
  
  -- Audit
  created_by_agent UUID,
  created_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_entity (entity_id, entity_type),
  INDEX idx_source_event (source_event_id),
  INDEX idx_field (field_name),
  INDEX idx_source_agent (source_agent_id)
);

-- ============================================================================
-- MATERIALIZED VIEW MANAGEMENT
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.view_rebuild_log (
  id BIGSERIAL PRIMARY KEY,
  rebuild_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What view
  view_name VARCHAR(255) NOT NULL,
  entity_type entity_type NOT NULL,
  
  -- Status
  status VARCHAR(50), -- 'PENDING', 'IN_PROGRESS', 'COMPLETE', 'FAILED'
  
  -- Progress
  events_processed INT DEFAULT 0,
  events_total INT,
  percent_complete INT DEFAULT 0,
  
  -- Timing
  started_at TIMESTAMP NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMP,
  duration_ms INT,
  
  -- Error handling
  error_message TEXT,
  
  INDEX idx_status (status),
  INDEX idx_started_at (started_at DESC),
  INDEX idx_view_name (view_name)
);

-- ============================================================================
-- FUNCTIONS FOR EVENT SOURCING
-- ============================================================================

-- Function to append event and update version
CREATE OR REPLACE FUNCTION events.append_event(
  p_aggregate_id UUID,
  p_aggregate_type entity_type,
  p_event_type VARCHAR,
  p_data JSONB,
  p_metadata JSONB DEFAULT '{}',
  p_expected_version INT DEFAULT NULL,
  p_created_by_agent UUID DEFAULT NULL,
  p_created_by_user UUID DEFAULT NULL,
  p_correlation_id UUID DEFAULT NULL,
  p_causation_id UUID DEFAULT NULL
)
RETURNS TABLE (
  event_id UUID,
  version INT,
  occurred_at TIMESTAMP
) AS $$
DECLARE
  v_new_version INT;
  v_current_version INT;
BEGIN
  -- Get current version
  SELECT COALESCE(MAX(version), 0)
  INTO v_current_version
  FROM events.event_log
  WHERE aggregate_id = p_aggregate_id
    AND aggregate_type = p_aggregate_type;
  
  -- Check optimistic locking
  IF p_expected_version IS NOT NULL AND p_expected_version != v_current_version THEN
    RAISE EXCEPTION 'Version conflict: expected %, got %', p_expected_version, v_current_version;
  END IF;
  
  v_new_version := v_current_version + 1;
  
  -- Insert event
  INSERT INTO events.event_log (
    aggregate_id,
    aggregate_type,
    event_type,
    data,
    metadata,
    version,
    expected_version,
    created_by_agent,
    created_by_user,
    correlation_id,
    causation_id
  ) VALUES (
    p_aggregate_id,
    p_aggregate_type,
    p_event_type,
    p_data,
    p_metadata,
    v_new_version,
    p_expected_version,
    p_created_by_agent,
    p_created_by_user,
    p_correlation_id,
    p_causation_id
  )
  RETURNING event_log.event_id, event_log.version, event_log.occurred_at
  INTO event_id, version, occurred_at;
  
  RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- Function to get aggregate state from events
CREATE OR REPLACE FUNCTION events.get_aggregate_state(
  p_aggregate_id UUID,
  p_aggregate_type entity_type
)
RETURNS TABLE (
  state JSONB,
  version INT,
  last_event_id UUID,
  last_event_at TIMESTAMP
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    el.data,
    el.version,
    el.event_id,
    el.occurred_at
  FROM events.event_log el
  WHERE el.aggregate_id = p_aggregate_id
    AND el.aggregate_type = p_aggregate_type
  ORDER BY el.version DESC
  LIMIT 1;
END;
$$ LANGUAGE plpgsql;

-- Function to get event history for aggregate
CREATE OR REPLACE FUNCTION events.get_event_history(
  p_aggregate_id UUID,
  p_aggregate_type entity_type,
  p_from_version INT DEFAULT 0,
  p_limit INT DEFAULT 100
)
RETURNS TABLE (
  event_id UUID,
  event_type VARCHAR,
  data JSONB,
  version INT,
  occurred_at TIMESTAMP,
  created_by_agent UUID,
  created_by_user UUID
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    el.event_id,
    el.event_type,
    el.data,
    el.version,
    el.occurred_at,
    el.created_by_agent,
    el.created_by_user
  FROM events.event_log el
  WHERE el.aggregate_id = p_aggregate_id
    AND el.aggregate_type = p_aggregate_type
    AND el.version > p_from_version
  ORDER BY el.version ASC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- TRIGGERS FOR EVENT LOG MAINTENANCE
-- ============================================================================

-- Automatically update updated_at on relevant tables
CREATE OR REPLACE FUNCTION events.update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_subscriptions_timestamp
BEFORE UPDATE ON events.event_subscriptions
FOR EACH ROW
EXECUTE FUNCTION events.update_timestamp();

-- ============================================================================
-- VIEWS FOR QUERYING
-- ============================================================================

CREATE OR REPLACE VIEW events.recent_events AS
SELECT 
  event_id,
  aggregate_id,
  aggregate_type,
  event_type,
  version,
  occurred_at,
  created_by_agent,
  created_by_user,
  data,
  LAG(version) OVER (PARTITION BY aggregate_id ORDER BY version) as previous_version
FROM events.event_log
WHERE occurred_at > NOW() - INTERVAL '24 hours'
ORDER BY occurred_at DESC;

CREATE OR REPLACE VIEW events.event_statistics AS
SELECT 
  aggregate_type,
  event_type,
  COUNT(*) as event_count,
  COUNT(DISTINCT aggregate_id) as aggregate_count,
  MIN(occurred_at) as first_occurrence,
  MAX(occurred_at) as last_occurrence,
  ROUND((COUNT(DISTINCT aggregate_id)::FLOAT / 
         MAX(NULLIF((SELECT COUNT(*) FROM events.event_log WHERE aggregate_type = el.aggregate_type), 0))::FLOAT * 100), 2) as coverage_percent
FROM events.event_log el
GROUP BY aggregate_type, event_type
ORDER BY event_count DESC;

-- ============================================================================
-- STATUS
-- ============================================================================

-- SELECT 'DIMENSION 1: EVENT SOURCING TABLES CREATED' as status;

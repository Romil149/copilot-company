-- DIMENSION 3 & 16: AGENT COLLABORATION & COMMUNICATION
-- Dependency graph, deadlock prevention, message schema
-- Version: 1.0

\c copilot_company

SET search_path TO core, agents, public;

-- ============================================================================
-- DEPENDENCY GRAPH (Dimension 3)
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.agent_dependencies (
  id BIGSERIAL PRIMARY KEY,
  dependency_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Dependency relationship
  dependent_agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  required_agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- Details
  dependency_type VARCHAR(50), -- 'DATA', 'DECISION', 'APPROVAL', 'SEQUENCING'
  description VARCHAR(500),
  
  -- Constraints
  max_wait_seconds INT DEFAULT 300,
  is_critical BOOLEAN DEFAULT FALSE, -- If fails, stop everything
  
  -- Status
  is_active BOOLEAN DEFAULT TRUE,
  
  created_at TIMESTAMP DEFAULT NOW(),
  
  UNIQUE (dependent_agent_id, required_agent_id, dependency_type),
  INDEX idx_dependent (dependent_agent_id),
  INDEX idx_required (required_agent_id),
  INDEX idx_type (dependency_type),
  INDEX idx_critical (is_critical)
);

CREATE TABLE IF NOT EXISTS core.dependency_cycles (
  id BIGSERIAL PRIMARY KEY,
  cycle_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- The cycle
  agents_in_cycle UUID[] NOT NULL,
  cycle_path VARCHAR(1000),
  
  -- Severity
  is_deadlock BOOLEAN DEFAULT TRUE,
  
  -- Detection
  detected_at TIMESTAMP NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMP,
  resolution_action VARCHAR(500),
  resolved_by_user UUID,
  
  -- Status
  status VARCHAR(50) DEFAULT 'OPEN', -- OPEN, RESOLVED, ESCALATED
  
  INDEX idx_status (status),
  INDEX idx_detected_at (detected_at DESC)
);

CREATE TABLE IF NOT EXISTS core.agent_wait_times (
  id BIGSERIAL PRIMARY KEY,
  wait_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Who waits for whom
  waiting_agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  required_from_agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- Dependency
  dependency_id UUID REFERENCES core.agent_dependencies(dependency_id),
  
  -- Timing
  wait_started_at TIMESTAMP NOT NULL DEFAULT NOW(),
  wait_ended_at TIMESTAMP,
  wait_duration_ms INT,
  
  -- Status
  status VARCHAR(50) DEFAULT 'WAITING', -- WAITING, COMPLETED, TIMEOUT, ESCALATED
  timeout_at TIMESTAMP,
  
  -- Reason
  reason VARCHAR(500),
  
  INDEX idx_waiting_agent (waiting_agent_id),
  INDEX idx_required_agent (required_from_agent_id),
  INDEX idx_status (status),
  INDEX idx_started_at (wait_started_at DESC)
);

-- ============================================================================
-- CYCLE DETECTION FUNCTIONS
-- ============================================================================

CREATE OR REPLACE FUNCTION core.detect_dependency_cycles()
RETURNS TABLE (
  cycle_detected BOOLEAN,
  agents_involved UUID[],
  cycle_path VARCHAR
) AS $$
WITH RECURSIVE cycle_finder AS (
  -- Start with each dependency
  SELECT 
    ad.dependent_agent_id as current_agent,
    ad.required_agent_id as next_agent,
    ARRAY[ad.dependent_agent_id, ad.required_agent_id] as path,
    1 as depth
  FROM core.agent_dependencies ad
  WHERE ad.is_active = TRUE
  
  UNION ALL
  
  -- Recursively follow dependencies
  SELECT 
    cf.current_agent,
    ad.required_agent_id,
    cf.path || ad.required_agent_id,
    cf.depth + 1
  FROM cycle_finder cf
  JOIN core.agent_dependencies ad ON cf.next_agent = ad.dependent_agent_id
  WHERE ad.is_active = TRUE
    AND cf.depth < 10 -- Prevent infinite recursion
    AND NOT (ad.required_agent_id = ANY(cf.path)) -- Prevent already-visited nodes
)
SELECT 
  TRUE as cycle_detected,
  path as agents_involved,
  array_to_string(path, ' -> ') as cycle_path
FROM cycle_finder
WHERE next_agent = current_agent
  AND depth > 2;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION core.check_deadlock(
  p_agent_id UUID
)
RETURNS TABLE (
  is_deadlocked BOOLEAN,
  cycle_detected BOOLEAN,
  affected_agents UUID[],
  wait_duration_seconds INT
) AS $$
DECLARE
  v_wait_duration INT;
  v_is_deadlocked BOOLEAN := FALSE;
  v_affected_agents UUID[] := ARRAY[]::UUID[];
BEGIN
  -- Check if agent is waiting
  SELECT 
    MAX(EXTRACT(EPOCH FROM (NOW() - wait_started_at)))::INT,
    ARRAY_AGG(DISTINCT waiting_agent_id)
  INTO v_wait_duration, v_affected_agents
  FROM core.agent_wait_times
  WHERE waiting_agent_id = p_agent_id
    AND status = 'WAITING'
    AND wait_duration_ms IS NULL;
  
  -- If waiting longer than timeout, it might be deadlocked
  IF v_wait_duration > 300 THEN
    v_is_deadlocked := TRUE;
  END IF;
  
  RETURN QUERY SELECT v_is_deadlocked, FALSE, v_affected_agents, v_wait_duration;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- MESSAGE SCHEMA & COMMUNICATION (Dimension 16)
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.message_schemas (
  id BIGSERIAL PRIMARY KEY,
  schema_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Definition
  message_type VARCHAR(100) NOT NULL UNIQUE,
  description TEXT,
  
  -- Schema
  schema_json JSONB NOT NULL,
  version VARCHAR(20) DEFAULT '1.0.0',
  
  -- Status
  is_active BOOLEAN DEFAULT TRUE,
  
  -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_message_type (message_type),
  INDEX idx_active (is_active)
);

CREATE TABLE IF NOT EXISTS core.agent_messages (
  id BIGSERIAL PRIMARY KEY,
  message_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Routing
  from_agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  to_agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- Message
  message_type VARCHAR(100) NOT NULL,
  payload JSONB NOT NULL,
  
  -- Correlation
  correlation_id UUID NOT NULL,
  causation_id UUID,
  
  -- Ordering
  sequence_number BIGINT,
  
  -- Status
  status VARCHAR(50) DEFAULT 'SENT', -- SENT, DELIVERED, ACKNOWLEDGED, FAILED
  
  -- Timing
  sent_at TIMESTAMP NOT NULL DEFAULT NOW(),
  delivered_at TIMESTAMP,
  acknowledged_at TIMESTAMP,
  
  -- Error handling
  retry_count INT DEFAULT 0,
  max_retries INT DEFAULT 3,
  next_retry_at TIMESTAMP,
  error_message TEXT,
  
  -- Metadata
  priority INT DEFAULT 5, -- 1-10, higher = more important
  
  INDEX idx_from_agent (from_agent_id),
  INDEX idx_to_agent (to_agent_id),
  INDEX idx_correlation (correlation_id),
  INDEX idx_status (status),
  INDEX idx_sent_at (sent_at DESC),
  INDEX idx_message_type (message_type)
);

CREATE TABLE IF NOT EXISTS core.message_acknowledgments (
  id BIGSERIAL PRIMARY KEY,
  ack_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Message
  message_id UUID NOT NULL REFERENCES core.agent_messages(message_id),
  
  -- Acknowledgment
  acknowledged_at TIMESTAMP NOT NULL DEFAULT NOW(),
  acknowledged_by_agent UUID NOT NULL,
  
  -- Response
  status VARCHAR(50), -- 'RECEIVED', 'PROCESSING', 'COMPLETED', 'FAILED'
  response_data JSONB,
  
  INDEX idx_message (message_id),
  INDEX idx_agent (acknowledged_by_agent)
);

CREATE TABLE IF NOT EXISTS core.message_validation_errors (
  id BIGSERIAL PRIMARY KEY,
  error_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Message
  message_id UUID NOT NULL,
  message_type VARCHAR(100) NOT NULL,
  
  -- Error
  error_type VARCHAR(50), -- 'SCHEMA_VALIDATION', 'TYPE_ERROR', 'REQUIRED_FIELD_MISSING'
  error_message TEXT NOT NULL,
  
  -- Problematic data
  invalid_payload JSONB,
  
  -- Timing
  detected_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  INDEX idx_message_type (message_type),
  INDEX idx_error_type (error_type)
);

-- ============================================================================
-- MESSAGE VALIDATION FUNCTIONS
-- ============================================================================

CREATE OR REPLACE FUNCTION core.validate_message(
  p_message_type VARCHAR,
  p_payload JSONB
)
RETURNS TABLE (
  is_valid BOOLEAN,
  validation_errors TEXT[]
) AS $$
DECLARE
  v_schema JSONB;
  v_errors TEXT[] := ARRAY[]::TEXT[];
BEGIN
  -- Get schema
  SELECT schema_json INTO v_schema
  FROM core.message_schemas
  WHERE message_type = p_message_type
    AND is_active = TRUE;
  
  IF v_schema IS NULL THEN
    v_errors := array_append(v_errors, 'Message type not found: ' || p_message_type);
    RETURN QUERY SELECT FALSE, v_errors;
    RETURN;
  END IF;
  
  -- Basic validation (in real scenario, use JSON Schema library)
  -- This is simplified - production would use jsonschema validation
  
  RETURN QUERY SELECT (array_length(v_errors, 1) IS NULL), v_errors;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION core.send_agent_message(
  p_from_agent_id UUID,
  p_to_agent_id UUID,
  p_message_type VARCHAR,
  p_payload JSONB,
  p_correlation_id UUID DEFAULT NULL,
  p_causation_id UUID DEFAULT NULL
)
RETURNS TABLE (
  message_id UUID,
  correlation_id UUID,
  status VARCHAR
) AS $$
DECLARE
  v_message_id UUID;
  v_correlation_id UUID;
  v_validation_valid BOOLEAN;
BEGIN
  -- Validate message
  SELECT (validate_message(p_message_type, p_payload)).is_valid
  INTO v_validation_valid;
  
  IF NOT v_validation_valid THEN
    RAISE EXCEPTION 'Message validation failed';
  END IF;
  
  v_correlation_id := COALESCE(p_correlation_id, uuid_generate_v4());
  
  -- Insert message
  INSERT INTO core.agent_messages (
    from_agent_id,
    to_agent_id,
    message_type,
    payload,
    correlation_id,
    causation_id
  ) VALUES (
    p_from_agent_id,
    p_to_agent_id,
    p_message_type,
    p_payload,
    v_correlation_id,
    p_causation_id
  )
  RETURNING agent_messages.message_id
  INTO v_message_id;
  
  RETURN QUERY SELECT v_message_id, v_correlation_id, 'SENT'::VARCHAR;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- STATUS
-- ============================================================================

-- SELECT 'DIMENSION 3 & 16: COLLABORATION & COMMUNICATION CREATED' as status;

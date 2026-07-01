-- DIMENSION 2: TEMPORAL QUERIES & TIME TRAVEL
-- Bitemporal data model with point-in-time recovery
-- Version: 1.0

\c copilot_company

SET search_path TO temporal, core, public;

-- ============================================================================
-- BITEMPORAL DATA MODEL
-- ============================================================================

-- Example bitemporal table for employees
CREATE TABLE IF NOT EXISTS temporal.employees_bitemporal (
  employee_id UUID NOT NULL,
  name VARCHAR(255),
  email VARCHAR(255),
  department VARCHAR(100),
  salary DECIMAL(12, 2),
  position_title VARCHAR(100),
  manager_id UUID,
  
  -- Validity: When this data is true in the real world
  valid_from TIMESTAMP NOT NULL,
  valid_to TIMESTAMP NOT NULL DEFAULT '9999-12-31'::TIMESTAMP,
  
  -- Transaction: When this data was recorded in the system
  transaction_from TIMESTAMP NOT NULL DEFAULT NOW(),
  transaction_to TIMESTAMP NOT NULL DEFAULT '9999-12-31'::TIMESTAMP,
  
  -- Is this the current record?
  is_current BOOLEAN DEFAULT TRUE,
  
  -- Who created/modified
  created_by_agent UUID,
  created_by_user UUID,
  modified_by_agent UUID,
  modified_by_user UUID,
  
  -- Source event
  source_event_id UUID,
  
  PRIMARY KEY (employee_id, valid_from, transaction_from)
);

CREATE INDEX idx_employees_current ON temporal.employees_bitemporal(employee_id, valid_to)
WHERE is_current = TRUE AND transaction_to = '9999-12-31'::TIMESTAMP;

CREATE INDEX idx_employees_valid_time ON temporal.employees_bitemporal(valid_from, valid_to);
CREATE INDEX idx_employees_transaction_time ON temporal.employees_bitemporal(transaction_from, transaction_to);

-- Template for other bitemporal tables
CREATE TABLE IF NOT EXISTS temporal.deals_bitemporal (
  deal_id UUID NOT NULL,
  company_name VARCHAR(255),
  amount DECIMAL(15, 2),
  stage VARCHAR(50),
  close_date DATE,
  
  -- Validity
  valid_from TIMESTAMP NOT NULL,
  valid_to TIMESTAMP NOT NULL DEFAULT '9999-12-31'::TIMESTAMP,
  
  -- Transaction
  transaction_from TIMESTAMP NOT NULL DEFAULT NOW(),
  transaction_to TIMESTAMP NOT NULL DEFAULT '9999-12-31'::TIMESTAMP,
  
  is_current BOOLEAN DEFAULT TRUE,
  created_by_agent UUID,
  modified_by_agent UUID,
  source_event_id UUID,
  
  PRIMARY KEY (deal_id, valid_from, transaction_from)
);

CREATE INDEX idx_deals_current ON temporal.deals_bitemporal(deal_id, valid_to)
WHERE is_current = TRUE AND transaction_to = '9999-12-31'::TIMESTAMP;

-- ============================================================================
-- POINT-IN-TIME SNAPSHOTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS temporal.point_in_time_snapshots (
  id BIGSERIAL PRIMARY KEY,
  snapshot_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- When this snapshot represents
  snapshot_as_of TIMESTAMP NOT NULL,
  
  -- When we created it
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  -- Metadata
  description VARCHAR(500),
  reason VARCHAR(100), -- 'SCHEDULED', 'MANUAL', 'EMERGENCY', 'INVESTIGATION'
  
  -- Verification
  is_verified BOOLEAN DEFAULT FALSE,
  verified_at TIMESTAMP,
  verification_notes TEXT,
  
  INDEX idx_snapshot_as_of (snapshot_as_of DESC),
  INDEX idx_created_at (created_at DESC),
  INDEX idx_reason (reason)
);

-- ============================================================================
-- TEMPORAL QUERIES FUNCTIONS
-- ============================================================================

-- Function: Get employee state as of a specific time
CREATE OR REPLACE FUNCTION temporal.get_employee_as_of(
  p_employee_id UUID,
  p_as_of_time TIMESTAMP
)
RETURNS TABLE (
  employee_id UUID,
  name VARCHAR,
  email VARCHAR,
  department VARCHAR,
  salary DECIMAL,
  position_title VARCHAR,
  valid_from TIMESTAMP,
  valid_to TIMESTAMP,
  as_of_time TIMESTAMP
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    eb.employee_id,
    eb.name,
    eb.email,
    eb.department,
    eb.salary,
    eb.position_title,
    eb.valid_from,
    eb.valid_to,
    p_as_of_time
  FROM temporal.employees_bitemporal eb
  WHERE eb.employee_id = p_employee_id
    AND eb.valid_from <= p_as_of_time
    AND eb.valid_to > p_as_of_time
    AND eb.transaction_to = '9999-12-31'::TIMESTAMP; -- Current version
END;
$$ LANGUAGE plpgsql;

-- Function: Get company state as of a specific time (all employees)
CREATE OR REPLACE FUNCTION temporal.get_company_state_as_of(
  p_as_of_time TIMESTAMP
)
RETURNS TABLE (
  employee_count INT,
  avg_salary DECIMAL,
  total_salary DECIMAL,
  departments TEXT[],
  as_of_time TIMESTAMP
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COUNT(DISTINCT employee_id)::INT,
    ROUND(AVG(salary), 2),
    ROUND(SUM(salary), 2),
    ARRAY_AGG(DISTINCT department),
    p_as_of_time
  FROM temporal.employees_bitemporal
  WHERE valid_from <= p_as_of_time
    AND valid_to > p_as_of_time
    AND transaction_to = '9999-12-31'::TIMESTAMP;
END;
$$ LANGUAGE plpgsql;

-- Function: Get full history of changes for an entity
CREATE OR REPLACE FUNCTION temporal.get_entity_history(
  p_entity_id UUID,
  p_entity_type VARCHAR
)
RETURNS TABLE (
  valid_from TIMESTAMP,
  valid_to TIMESTAMP,
  transaction_from TIMESTAMP,
  transaction_to TIMESTAMP,
  data_snapshot JSONB,
  change_type VARCHAR
) AS $$
BEGIN
  -- This is a template - actual implementation depends on entity type
  -- For now, return empty result set
  RETURN;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- TEMPORAL VIEWS
-- ============================================================================

-- Current employees view (simplification)
CREATE OR REPLACE VIEW temporal.employees_current AS
SELECT 
  employee_id,
  name,
  email,
  department,
  salary,
  position_title,
  manager_id,
  valid_from,
  valid_to
FROM temporal.employees_bitemporal
WHERE is_current = TRUE
  AND valid_to = '9999-12-31'::TIMESTAMP
  AND transaction_to = '9999-12-31'::TIMESTAMP;

-- Historical changes view
CREATE OR REPLACE VIEW temporal.employee_changes_history AS
SELECT 
  employee_id,
  name,
  email,
  department,
  salary,
  valid_from,
  valid_to,
  valid_to - valid_from as tenure_in_this_state,
  transaction_from,
  LAG(salary) OVER (PARTITION BY employee_id ORDER BY transaction_from) as previous_salary
FROM temporal.employees_bitemporal
ORDER BY employee_id, transaction_from DESC;

-- ============================================================================
-- SCENARIO REPLAY SYSTEM
-- ============================================================================

CREATE TABLE IF NOT EXISTS temporal.scenario_replays (
  id BIGSERIAL PRIMARY KEY,
  replay_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What scenario
  name VARCHAR(255) NOT NULL,
  description TEXT,
  
  -- Replay parameters
  start_time TIMESTAMP NOT NULL,
  end_time TIMESTAMP,
  hypothetical_change_id UUID,
  hypothetical_change JSONB,
  
  -- Results
  original_outcome JSONB,
  simulated_outcome JSONB,
  impact_analysis JSONB,
  
  -- Metadata
  created_by_user UUID,
  created_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_start_time (start_time DESC),
  INDEX idx_created_at (created_at DESC)
);

-- ============================================================================
-- STATUS
-- ============================================================================

-- SELECT 'DIMENSION 2: TEMPORAL TABLES CREATED' as status;

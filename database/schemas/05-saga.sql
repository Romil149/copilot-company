-- DIMENSION 5: SAGA PATTERN & DISTRIBUTED TRANSACTIONS
-- Compensation-based transaction management
-- Version: 1.0

\c copilot_company

SET search_path TO core, events, public;

-- ============================================================================
-- SAGA DEFINITIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.saga_definitions (
  id BIGSERIAL PRIMARY KEY,
  saga_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Definition
  name VARCHAR(255) NOT NULL UNIQUE,
  description TEXT,
  
  -- Status
  is_active BOOLEAN DEFAULT TRUE,
  version VARCHAR(20) DEFAULT '1.0.0',
  
  -- Configuration
  config_json JSONB DEFAULT '{}',
  
  -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_name (name),
  INDEX idx_active (is_active)
);

-- ============================================================================
-- SAGA STEPS
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.saga_steps (
  id BIGSERIAL PRIMARY KEY,
  step_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What saga
  saga_id UUID NOT NULL REFERENCES core.saga_definitions(saga_id),
  
  -- Order
  step_number INT NOT NULL,
  
  -- Step definition
  step_name VARCHAR(255) NOT NULL,
  description TEXT,
  
  -- Service/Action
  service_name VARCHAR(255) NOT NULL,
  action_name VARCHAR(255) NOT NULL,
  
  -- Parameters
  parameters_schema JSONB,
  
  -- Compensation
  has_compensation BOOLEAN DEFAULT TRUE,
  compensation_service VARCHAR(255),
  compensation_action VARCHAR(255),
  compensation_parameters_schema JSONB,
  
  -- Timeout
  timeout_seconds INT DEFAULT 300,
  
  -- Retry
  max_retries INT DEFAULT 3,
  retry_backoff_ms INT DEFAULT 1000,
  
  -- Status
  is_enabled BOOLEAN DEFAULT TRUE,
  
  UNIQUE (saga_id, step_number),
  INDEX idx_saga (saga_id),
  INDEX idx_service (service_name)
);

-- ============================================================================
-- SAGA EXECUTIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.saga_executions (
  id BIGSERIAL PRIMARY KEY,
  execution_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What saga
  saga_id UUID NOT NULL REFERENCES core.saga_definitions(saga_id),
  
  -- Identity
  correlation_id UUID NOT NULL,
  causation_id UUID,
  
  -- State
  status VARCHAR(50) DEFAULT 'STARTED', -- STARTED, IN_PROGRESS, COMPLETED, COMPENSATING, COMPENSATED, FAILED
  
  -- Current step
  current_step_number INT,
  current_step_status VARCHAR(50), -- PENDING, IN_PROGRESS, COMPLETED, FAILED, COMPENSATING
  
  -- Data
  input_data JSONB NOT NULL,
  output_data JSONB,
  
  -- Compensation
  is_compensating BOOLEAN DEFAULT FALSE,
  compensation_reason VARCHAR(500),
  
  -- Timing
  started_at TIMESTAMP NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMP,
  duration_ms INT,
  
  -- Metadata
  created_by_agent UUID,
  created_by_user UUID,
  
  INDEX idx_saga (saga_id),
  INDEX idx_correlation (correlation_id),
  INDEX idx_status (status),
  INDEX idx_started_at (started_at DESC)
);

-- ============================================================================
-- SAGA STEP EXECUTIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.saga_step_executions (
  id BIGSERIAL PRIMARY KEY,
  step_execution_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What execution and step
  execution_id UUID NOT NULL REFERENCES core.saga_executions(execution_id),
  step_id UUID NOT NULL REFERENCES core.saga_steps(step_id),
  
  -- Status
  status VARCHAR(50) DEFAULT 'PENDING', -- PENDING, IN_PROGRESS, COMPLETED, FAILED, COMPENSATING, COMPENSATED
  
  -- Attempts
  attempt_number INT DEFAULT 1,
  max_retries INT,
  
  -- Request/Response
  request_data JSONB,
  response_data JSONB,
  
  -- Error handling
  error_message TEXT,
  error_code VARCHAR(50),
  
  -- Timing
  started_at TIMESTAMP DEFAULT NOW(),
  completed_at TIMESTAMP,
  duration_ms INT,
  
  -- Compensation
  compensated_at TIMESTAMP,
  compensation_status VARCHAR(50),
  compensation_response JSONB,
  
  -- Metadata
  idempotency_key UUID NOT NULL,
  
  INDEX idx_execution (execution_id),
  INDEX idx_step (step_id),
  INDEX idx_status (status),
  INDEX idx_idempotency (idempotency_key)
);

-- ============================================================================
-- IDEMPOTENCY KEYS (Prevent Duplicates)
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.idempotency_keys (
  id BIGSERIAL PRIMARY KEY,
  key_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- The key
  idempotency_key UUID NOT NULL UNIQUE,
  
  -- What operation
  operation_type VARCHAR(100) NOT NULL,
  operation_id UUID,
  
  -- Result
  result_data JSONB,
  result_status VARCHAR(50), -- SUCCESS, FAILED, PROCESSING
  
  -- Expiration (24 hours)
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMP NOT NULL DEFAULT (NOW() + INTERVAL '24 hours'),
  
  INDEX idx_idempotency_key (idempotency_key),
  INDEX idx_operation (operation_type, operation_id),
  INDEX idx_expires_at (expires_at)
);

-- ============================================================================
-- PREDEFINED SAGAS
-- ============================================================================

-- Saga: Hire Employee
INSERT INTO core.saga_definitions (name, description)
VALUES 
  ('HireEmployee', 'Hire new employee: Create ATS, Setup payroll, Create email'),
  ('WinDeal', 'Win deal: Create invoice, Update revenue forecast, Send confirmation'),
  ('DeleteCustomer', 'Delete customer: Archive deals, Revoke access, Backup data')
ON CONFLICT (name) DO NOTHING;

-- HireEmployee steps
INSERT INTO core.saga_steps (
  saga_id, step_number, step_name, service_name, action_name,
  has_compensation, compensation_service, compensation_action
)
SELECT 
  sd.saga_id, 1, 'Create in ATS', 'ATS', 'CreateEmployee',
  TRUE, 'ATS', 'DeleteEmployee'
FROM core.saga_definitions sd
WHERE sd.name = 'HireEmployee'
ON CONFLICT DO NOTHING;

INSERT INTO core.saga_steps (
  saga_id, step_number, step_name, service_name, action_name,
  has_compensation, compensation_service, compensation_action
)
SELECT 
  sd.saga_id, 2, 'Setup Payroll', 'Payroll', 'SetupPayrollAccount',
  TRUE, 'Payroll', 'DeletePayrollAccount'
FROM core.saga_definitions sd
WHERE sd.name = 'HireEmployee'
ON CONFLICT DO NOTHING;

INSERT INTO core.saga_steps (
  saga_id, step_number, step_name, service_name, action_name,
  has_compensation, compensation_service, compensation_action
)
SELECT 
  sd.saga_id, 3, 'Create Email', 'Email', 'CreateEmailAccount',
  TRUE, 'Email', 'DeleteEmailAccount'
FROM core.saga_definitions sd
WHERE sd.name = 'HireEmployee'
ON CONFLICT DO NOTHING;

-- ============================================================================
-- FUNCTIONS FOR SAGA ORCHESTRATION
-- ============================================================================

-- Start saga execution
CREATE OR REPLACE FUNCTION core.start_saga_execution(
  p_saga_name VARCHAR,
  p_input_data JSONB,
  p_correlation_id UUID DEFAULT NULL,
  p_causation_id UUID DEFAULT NULL,
  p_created_by_agent UUID DEFAULT NULL,
  p_created_by_user UUID DEFAULT NULL
)
RETURNS TABLE (
  execution_id UUID,
  correlation_id UUID,
  status VARCHAR
) AS $$
DECLARE
  v_saga_id UUID;
  v_execution_id UUID;
  v_correlation_id UUID;
BEGIN
  -- Get saga definition
  SELECT saga_id INTO v_saga_id
  FROM core.saga_definitions
  WHERE name = p_saga_name;
  
  IF v_saga_id IS NULL THEN
    RAISE EXCEPTION 'Saga not found: %', p_saga_name;
  END IF;
  
  -- Use provided correlation ID or generate new one
  v_correlation_id := COALESCE(p_correlation_id, uuid_generate_v4());
  
  -- Create execution record
  INSERT INTO core.saga_executions (
    saga_id,
    correlation_id,
    causation_id,
    input_data,
    created_by_agent,
    created_by_user
  ) VALUES (
    v_saga_id,
    v_correlation_id,
    p_causation_id,
    p_input_data,
    p_created_by_agent,
    p_created_by_user
  )
  RETURNING saga_executions.execution_id
  INTO v_execution_id;
  
  RETURN QUERY SELECT v_execution_id, v_correlation_id, 'STARTED'::VARCHAR;
END;
$$ LANGUAGE plpgsql;

-- Record step execution
CREATE OR REPLACE FUNCTION core.record_saga_step_execution(
  p_execution_id UUID,
  p_step_number INT,
  p_status VARCHAR,
  p_request_data JSONB DEFAULT NULL,
  p_response_data JSONB DEFAULT NULL,
  p_error_message VARCHAR DEFAULT NULL
)
RETURNS TABLE (
  step_execution_id UUID,
  status VARCHAR
) AS $$
DECLARE
  v_step_id UUID;
  v_step_execution_id UUID;
  v_idempotency_key UUID;
BEGIN
  -- Get step definition
  SELECT ss.step_id INTO v_step_id
  FROM core.saga_steps ss
  WHERE ss.saga_id = (
    SELECT saga_id FROM core.saga_executions WHERE execution_id = p_execution_id
  )
  AND ss.step_number = p_step_number;
  
  IF v_step_id IS NULL THEN
    RAISE EXCEPTION 'Step not found';
  END IF;
  
  -- Generate idempotency key
  v_idempotency_key := uuid_generate_v4();
  
  -- Record step execution
  INSERT INTO core.saga_step_executions (
    execution_id,
    step_id,
    status,
    request_data,
    response_data,
    error_message,
    idempotency_key
  ) VALUES (
    p_execution_id,
    v_step_id,
    p_status,
    p_request_data,
    p_response_data,
    p_error_message,
    v_idempotency_key
  )
  RETURNING saga_step_executions.step_execution_id
  INTO v_step_execution_id;
  
  -- Update saga execution current step
  UPDATE core.saga_executions
  SET 
    current_step_number = p_step_number,
    current_step_status = p_status,
    updated_at = NOW()
  WHERE execution_id = p_execution_id;
  
  RETURN QUERY SELECT v_step_execution_id, p_status::VARCHAR;
END;
$$ LANGUAGE plpgsql;

-- Complete saga execution
CREATE OR REPLACE FUNCTION core.complete_saga_execution(
  p_execution_id UUID,
  p_output_data JSONB DEFAULT NULL
)
RETURNS TABLE (
  execution_id UUID,
  status VARCHAR,
  duration_ms INT
) AS $$
DECLARE
  v_started_at TIMESTAMP;
  v_duration_ms INT;
BEGIN
  -- Get start time
  SELECT started_at INTO v_started_at
  FROM core.saga_executions
  WHERE execution_id = p_execution_id;
  
  v_duration_ms := EXTRACT(EPOCH FROM (NOW() - v_started_at))::INT * 1000;
  
  -- Update execution
  UPDATE core.saga_executions
  SET 
    status = 'COMPLETED',
    output_data = p_output_data,
    completed_at = NOW(),
    duration_ms = v_duration_ms,
    updated_at = NOW()
  WHERE execution_id = p_execution_id;
  
  RETURN QUERY SELECT p_execution_id, 'COMPLETED'::VARCHAR, v_duration_ms;
END;
$$ LANGUAGE plpgsql;

-- Compensate (rollback) saga
CREATE OR REPLACE FUNCTION core.compensate_saga_execution(
  p_execution_id UUID,
  p_reason VARCHAR DEFAULT 'Manual compensation'
)
RETURNS TABLE (
  execution_id UUID,
  status VARCHAR
) AS $$
BEGIN
  -- Mark as compensating
  UPDATE core.saga_executions
  SET 
    status = 'COMPENSATING',
    is_compensating = TRUE,
    compensation_reason = p_reason,
    updated_at = NOW()
  WHERE execution_id = p_execution_id;
  
  -- Steps will be compensated in reverse order
  -- This should be handled by the saga orchestrator service
  
  RETURN QUERY SELECT p_execution_id, 'COMPENSATING'::VARCHAR;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- STATUS
-- ============================================================================

-- SELECT 'DIMENSION 5: SAGA ORCHESTRATION CREATED' as status;

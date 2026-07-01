-- DIMENSION 4: STATE MACHINES & WORKFLOW VALIDATION
-- Entity lifecycle management with valid transitions
-- Version: 1.0

\c copilot_company

SET search_path TO core, events, public;

-- ============================================================================
-- STATE MACHINE DEFINITIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.state_machines (
  id BIGSERIAL PRIMARY KEY,
  state_machine_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Definition
  entity_type entity_type NOT NULL UNIQUE,
  name VARCHAR(255) NOT NULL,
  description TEXT,
  
  -- Initial state
  initial_state VARCHAR(50) NOT NULL,
  
  -- Metadata
  version VARCHAR(20) DEFAULT '1.0.0',
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_entity_type (entity_type)
);

CREATE TABLE IF NOT EXISTS core.state_transitions (
  id BIGSERIAL PRIMARY KEY,
  transition_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What state machine
  state_machine_id UUID NOT NULL REFERENCES core.state_machines(state_machine_id),
  
  -- From/To
  from_state VARCHAR(50) NOT NULL,
  to_state VARCHAR(50) NOT NULL,
  
  -- Rules
  is_allowed BOOLEAN DEFAULT TRUE,
  required_conditions JSONB DEFAULT '[]',
  
  -- Hooks
  pre_transition_action VARCHAR(255),
  post_transition_action VARCHAR(255),
  
  -- Metadata
  description VARCHAR(500),
  requires_approval BOOLEAN DEFAULT FALSE,
  approval_roles TEXT[] DEFAULT '{}',
  
  created_at TIMESTAMP DEFAULT NOW(),
  
  UNIQUE (state_machine_id, from_state, to_state),
  INDEX idx_state_machine (state_machine_id),
  INDEX idx_allowed (is_allowed)
);

CREATE TABLE IF NOT EXISTS core.entity_states (
  id BIGSERIAL PRIMARY KEY,
  
  -- Entity
  entity_id UUID NOT NULL,
  entity_type entity_type NOT NULL,
  
  -- Current state
  current_state VARCHAR(50) NOT NULL,
  
  -- History
  previous_state VARCHAR(50),
  state_changed_at TIMESTAMP DEFAULT NOW(),
  state_change_reason VARCHAR(500),
  
  -- Who changed it
  changed_by_agent UUID,
  changed_by_user UUID,
  
  -- Approval info (if needed)
  requires_approval BOOLEAN DEFAULT FALSE,
  approved_at TIMESTAMP,
  approved_by_user UUID,
  
  -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  UNIQUE (entity_id, entity_type),
  INDEX idx_entity (entity_id, entity_type),
  INDEX idx_current_state (current_state),
  INDEX idx_changed_at (state_changed_at DESC)
);

CREATE TABLE IF NOT EXISTS core.state_transition_log (
  id BIGSERIAL PRIMARY KEY,
  transition_log_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Entity
  entity_id UUID NOT NULL,
  entity_type entity_type NOT NULL,
  
  -- Transition
  from_state VARCHAR(50) NOT NULL,
  to_state VARCHAR(50) NOT NULL,
  
  -- Details
  transition_data JSONB,
  reason VARCHAR(500),
  
  -- Who
  initiated_by_agent UUID,
  initiated_by_user UUID,
  
  -- Timing
  initiated_at TIMESTAMP NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMP,
  
  -- Status
  status VARCHAR(50) DEFAULT 'COMPLETED', -- PENDING, COMPLETED, ROLLED_BACK, FAILED
  error_message TEXT,
  
  -- Post-transition actions
  post_actions JSONB, -- Which actions were triggered
  
  INDEX idx_entity (entity_id, entity_type),
  INDEX idx_states (from_state, to_state),
  INDEX idx_initiated_at (initiated_at DESC),
  INDEX idx_status (status)
);

-- ============================================================================
-- PRE-DEFINED STATE MACHINES
-- ============================================================================

INSERT INTO core.state_machines (entity_type, name, description, initial_state)
VALUES 
  ('Deal', 'Deal Lifecycle', 'States for managing sales deals', 'Draft'),
  ('Invoice', 'Invoice Workflow', 'States for invoice processing', 'Draft'),
  ('Project', 'Project Lifecycle', 'States for project management', 'Discovery'),
  ('Employee', 'Employee Lifecycle', 'States for employee management', 'Prospect')
ON CONFLICT (entity_type) DO NOTHING;

-- Deal transitions
INSERT INTO core.state_transitions (state_machine_id, from_state, to_state, is_allowed, requires_approval, description)
SELECT 
  sm.state_machine_id,
  'Draft',
  'Proposed',
  TRUE,
  FALSE,
  'Ready to propose to customer'
FROM core.state_machines sm
WHERE sm.entity_type = 'Deal'
ON CONFLICT DO NOTHING;

INSERT INTO core.state_transitions (state_machine_id, from_state, to_state, is_allowed, requires_approval, description)
SELECT 
  sm.state_machine_id,
  'Proposed',
  'Negotiation',
  TRUE,
  FALSE,
  'Customer engaged, negotiation started'
FROM core.state_machines sm
WHERE sm.entity_type = 'Deal'
ON CONFLICT DO NOTHING;

INSERT INTO core.state_transitions (state_machine_id, from_state, to_state, is_allowed, requires_approval, description)
SELECT 
  sm.state_machine_id,
  'Negotiation',
  'Won',
  TRUE,
  FALSE,
  'Contract signed, deal won'
FROM core.state_machines sm
WHERE sm.entity_type = 'Deal'
ON CONFLICT DO NOTHING;

INSERT INTO core.state_transitions (state_machine_id, from_state, to_state, is_allowed, requires_approval, description)
SELECT 
  sm.state_machine_id,
  'Negotiation',
  'Lost',
  TRUE,
  FALSE,
  'Customer declined'
FROM core.state_machines sm
WHERE sm.entity_type = 'Deal'
ON CONFLICT DO NOTHING;

INSERT INTO core.state_transitions (state_machine_id, from_state, to_state, is_allowed, requires_approval, description)
SELECT 
  sm.state_machine_id,
  'Draft',
  'Won',
  FALSE,
  FALSE,
  'Cannot skip to won (missing steps)'
FROM core.state_machines sm
WHERE sm.entity_type = 'Deal'
ON CONFLICT DO NOTHING;

-- ============================================================================
-- FUNCTIONS FOR STATE MACHINE VALIDATION
-- ============================================================================

CREATE OR REPLACE FUNCTION core.can_transition(
  p_entity_id UUID,
  p_entity_type entity_type,
  p_to_state VARCHAR
)
RETURNS TABLE (
  can_transition BOOLEAN,
  reason VARCHAR
) AS $$
DECLARE
  v_current_state VARCHAR;
  v_transition_allowed BOOLEAN;
BEGIN
  -- Get current state
  SELECT current_state INTO v_current_state
  FROM core.entity_states
  WHERE entity_id = p_entity_id AND entity_type = p_entity_type;
  
  IF v_current_state IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Entity not found';
    RETURN;
  END IF;
  
  -- Check transition
  SELECT is_allowed INTO v_transition_allowed
  FROM core.state_transitions st
  WHERE st.state_machine_id = (
    SELECT state_machine_id FROM core.state_machines WHERE entity_type = p_entity_type
  )
  AND st.from_state = v_current_state
  AND st.to_state = p_to_state;
  
  IF v_transition_allowed IS NULL THEN
    RETURN QUERY SELECT FALSE, FORMAT('No transition from %s to %s', v_current_state, p_to_state);
  ELSIF v_transition_allowed = FALSE THEN
    RETURN QUERY SELECT FALSE, 'Transition not allowed';
  ELSE
    RETURN QUERY SELECT TRUE, 'Transition allowed';
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION core.attempt_state_transition(
  p_entity_id UUID,
  p_entity_type entity_type,
  p_to_state VARCHAR,
  p_reason VARCHAR DEFAULT NULL,
  p_initiated_by_agent UUID DEFAULT NULL,
  p_initiated_by_user UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message VARCHAR,
  old_state VARCHAR,
  new_state VARCHAR
) AS $$
DECLARE
  v_current_state VARCHAR;
  v_can_transition BOOLEAN;
  v_transition_reason VARCHAR;
BEGIN
  -- Check if transition is allowed
  SELECT (can_transition).can_transition, (can_transition).reason
  INTO v_can_transition, v_transition_reason
  FROM (
    SELECT core.can_transition(p_entity_id, p_entity_type, p_to_state) as can_transition
  ) x;
  
  IF NOT v_can_transition THEN
    RETURN QUERY SELECT FALSE, v_transition_reason, NULL, NULL;
    RETURN;
  END IF;
  
  -- Get current state
  SELECT current_state INTO v_current_state
  FROM core.entity_states
  WHERE entity_id = p_entity_id AND entity_type = p_entity_type;
  
  -- Update entity state
  UPDATE core.entity_states
  SET 
    previous_state = current_state,
    current_state = p_to_state,
    state_changed_at = NOW(),
    state_change_reason = p_reason,
    changed_by_agent = p_initiated_by_agent,
    changed_by_user = p_initiated_by_user,
    updated_at = NOW()
  WHERE entity_id = p_entity_id AND entity_type = p_entity_type;
  
  -- Log transition
  INSERT INTO core.state_transition_log (
    entity_id,
    entity_type,
    from_state,
    to_state,
    reason,
    initiated_by_agent,
    initiated_by_user,
    status
  ) VALUES (
    p_entity_id,
    p_entity_type,
    v_current_state,
    p_to_state,
    p_reason,
    p_initiated_by_agent,
    p_initiated_by_user,
    'COMPLETED'
  );
  
  RETURN QUERY SELECT TRUE, 'Transition successful', v_current_state, p_to_state;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- STATUS
-- ============================================================================

-- SELECT 'DIMENSION 4: STATE MACHINES CREATED' as status;

-- PHASE 1 WEEK 1: CORE SYSTEM INITIALIZATION
-- Database setup and foundational tables
-- Version: 1.0
-- Status: READY FOR PHASE 1

-- Create database (if needed)
CREATE DATABASE IF NOT EXISTS copilot_company 
  WITH ENCODING 'UTF8' 
  LOCALE 'en_US.UTF-8';

\c copilot_company

-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "hstore";

-- Create schemas
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS events;
CREATE SCHEMA IF NOT EXISTS temporal;
CREATE SCHEMA IF NOT EXISTS agents;
CREATE SCHEMA IF NOT EXISTS monitoring;
CREATE SCHEMA IF NOT EXISTS security;
CREATE SCHEMA IF NOT EXISTS budget;
CREATE SCHEMA IF NOT EXISTS compliance;

-- Set search path
SET search_path TO core, public;

-- ============================================================================
-- ENUMS & TYPES
-- ============================================================================

CREATE TYPE entity_type AS ENUM (
  'Deal',
  'Invoice',
  'Employee',
  'Project',
  'Customer',
  'Contract',
  'Budget',
  'Expense',
  'Task',
  'Deliverable'
);

CREATE TYPE data_classification AS ENUM (
  'PUBLIC',
  'INTERNAL',
  'CONFIDENTIAL',
  'RESTRICTED',
  'PII',
  'PCI',
  'PHI'
);

CREATE TYPE agent_status AS ENUM (
  'INITIALIZING',
  'RUNNING',
  'IDLE',
  'PAUSED',
  'ERROR',
  'RECOVERING',
  'SHUTDOWN'
);

CREATE TYPE spending_authority AS ENUM (
  'AUTO_APPROVE_UNDER_100',
  'REQUIRES_TEAM_LEAD',
  'REQUIRES_MANAGER',
  'REQUIRES_VP',
  'REQUIRES_CFO',
  'REQUIRES_CEO'
);

-- ============================================================================
-- AUDIT & METADATA TABLES
-- ============================================================================

CREATE TABLE core.organizations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name VARCHAR(255) NOT NULL UNIQUE,
  description TEXT,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE core.users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organization_id UUID NOT NULL REFERENCES core.organizations(id),
  username VARCHAR(255) NOT NULL UNIQUE,
  email VARCHAR(255) NOT NULL UNIQUE,
  role VARCHAR(50) NOT NULL, -- CEO, CFO, VP_Sales, etc
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE core.api_tokens (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  token_hash VARCHAR(255) NOT NULL UNIQUE,
  description VARCHAR(255),
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT NOW(),
  expires_at TIMESTAMP,
  last_used_at TIMESTAMP
);

-- ============================================================================
-- DIMENSION 1: EVENT SOURCING (Immutable Log)
-- ============================================================================

CREATE TABLE events.event_log (
  id BIGSERIAL PRIMARY KEY,
  event_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What changed
  aggregate_id UUID NOT NULL,
  aggregate_type entity_type NOT NULL,
  
  -- Event metadata
  event_type VARCHAR(100) NOT NULL,
  data JSONB NOT NULL,
  metadata JSONB DEFAULT '{}',
  
  -- Timing
  occurred_at TIMESTAMP NOT NULL DEFAULT NOW(),
  recorded_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  -- Versioning
  version INT NOT NULL,
  expected_version INT,
  
  -- Causality tracking
  correlation_id UUID,
  causation_id UUID,
  
  -- Agent/User attribution
  created_by_agent UUID,
  created_by_user UUID REFERENCES core.users(id),
  
  -- Data classification
  data_classification data_classification DEFAULT 'INTERNAL',
  
  -- Indexes
  INDEX idx_aggregate (aggregate_id, aggregate_type),
  INDEX idx_event_type (event_type),
  INDEX idx_occurred_at (occurred_at DESC),
  INDEX idx_correlation (correlation_id),
  INDEX idx_created_by_agent (created_by_agent),
  INDEX idx_data_classification (data_classification)
);

-- Immutability trigger
CREATE OR REPLACE FUNCTION events.prevent_event_update()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'Event log is immutable. Cannot UPDATE.';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_event_update
BEFORE UPDATE ON events.event_log
FOR EACH ROW EXECUTE FUNCTION events.prevent_event_update();

-- ============================================================================
-- DIMENSION 1: CQRS PATTERN (Materialized Views)
-- ============================================================================

CREATE TABLE core.materialized_views (
  id BIGSERIAL PRIMARY KEY,
  view_name VARCHAR(255) NOT NULL UNIQUE,
  entity_type entity_type NOT NULL,
  
  -- Current state
  data JSONB NOT NULL,
  
  -- Versioning
  event_version INT NOT NULL,
  last_event_id UUID NOT NULL REFERENCES events.event_log(event_id),
  
  -- Timing
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_entity_type (entity_type),
  INDEX idx_event_version (event_version)
);

-- ============================================================================
-- DIMENSION 2: TEMPORAL QUERIES (Bitemporal Data)
-- ============================================================================

CREATE TABLE core.snapshot_log (
  id BIGSERIAL PRIMARY KEY,
  snapshot_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- When this snapshot is "valid" in business
  snapshot_at TIMESTAMP NOT NULL,
  
  -- When we recorded it
  recorded_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  -- Full state compressed
  state_json BYTEA NOT NULL, -- Compressed JSONB
  size_mb DECIMAL(10, 2),
  compression_ratio DECIMAL(3, 2),
  
  -- Quality
  is_verified BOOLEAN DEFAULT FALSE,
  verification_error TEXT,
  
  INDEX idx_snapshot_at (snapshot_at DESC),
  INDEX idx_recorded_at (recorded_at DESC)
);

-- ============================================================================
-- DIMENSION 12: DATA CONSISTENCY (Locking & Conflict Resolution)
-- ============================================================================

CREATE TABLE core.distributed_locks (
  id BIGSERIAL PRIMARY KEY,
  lock_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What's locked
  resource_type VARCHAR(100) NOT NULL,
  resource_id UUID NOT NULL,
  
  -- Who holds it
  held_by_agent UUID,
  held_by_user UUID REFERENCES core.users(id),
  
  -- Timing
  acquired_at TIMESTAMP NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMP NOT NULL DEFAULT (NOW() + INTERVAL '5 minutes'),
  released_at TIMESTAMP,
  
  -- Status
  is_active BOOLEAN DEFAULT TRUE,
  
  INDEX idx_resource (resource_type, resource_id),
  INDEX idx_active (is_active),
  INDEX idx_expires_at (expires_at)
);

CREATE TABLE core.conflict_log (
  id BIGSERIAL PRIMARY KEY,
  conflict_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What conflicted
  entity_id UUID NOT NULL,
  field_name VARCHAR(100) NOT NULL,
  
  -- The two versions
  version_1 JSONB NOT NULL,
  version_2 JSONB NOT NULL,
  
  -- Who/what caused it
  agent_1_id UUID,
  agent_2_id UUID,
  
  -- Resolution
  resolution_strategy VARCHAR(50), -- 'LWW', 'HVV', 'MANUAL', 'MERGED'
  resolved_value JSONB,
  resolved_at TIMESTAMP,
  resolved_by_user UUID REFERENCES core.users(id),
  
  -- Status
  status VARCHAR(50) DEFAULT 'OPEN', -- OPEN, RESOLVED, ESCALATED
  
  INDEX idx_entity (entity_id),
  INDEX idx_status (status),
  INDEX idx_created_at (created_at)
);

-- ============================================================================
-- DIMENSION 14: PRIVACY & DATA SENSITIVITY (DLP)
-- ============================================================================

CREATE TABLE security.data_classification_rules (
  id BIGSERIAL PRIMARY KEY,
  rule_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Pattern matching
  pattern_type VARCHAR(50), -- 'REGEX', 'EXACT', 'CONTAINS'
  pattern_value VARCHAR(1000) NOT NULL,
  
  -- Classification
  classification data_classification NOT NULL,
  
  -- Action
  action VARCHAR(50), -- 'ALLOW', 'REDACT', 'BLOCK', 'ENCRYPT'
  
  -- Metadata
  name VARCHAR(255),
  description TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_classification (classification),
  INDEX idx_active (is_active)
);

CREATE TABLE security.sensitive_data_access_log (
  id BIGSERIAL PRIMARY KEY,
  access_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What was accessed
  entity_id UUID NOT NULL,
  entity_type entity_type NOT NULL,
  data_classification data_classification NOT NULL,
  
  -- Who accessed it
  accessed_by_agent UUID,
  accessed_by_user UUID REFERENCES core.users(id),
  
  -- How
  access_method VARCHAR(50), -- 'API', 'UI', 'BATCH', 'REPORT'
  
  -- Timing
  accessed_at TIMESTAMP NOT NULL DEFAULT NOW(),
  duration_ms INT,
  
  -- Justification
  reason VARCHAR(255),
  
  INDEX idx_entity (entity_id),
  INDEX idx_classification (data_classification),
  INDEX idx_accessed_by_agent (accessed_by_agent),
  INDEX idx_accessed_at (accessed_at DESC)
);

-- ============================================================================
-- DIMENSION 17: BUDGET TRACKING & FINANCIAL CONTROLS
-- ============================================================================

CREATE TABLE budget.budget_allocations (
  id BIGSERIAL PRIMARY KEY,
  budget_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Hierarchy
  parent_budget_id UUID REFERENCES budget.budget_allocations(budget_id),
  level VARCHAR(50), -- 'ANNUAL', 'QUARTERLY', 'DEPARTMENT', 'AGENT'
  
  -- Scope
  organization_id UUID NOT NULL REFERENCES core.organizations(id),
  department VARCHAR(100),
  agent_id UUID,
  
  -- Amount
  total_budget DECIMAL(15, 2) NOT NULL,
  currency VARCHAR(3) DEFAULT 'USD',
  
  -- Period
  fiscal_year INT NOT NULL,
  quarter INT, -- 1-4
  month INT,   -- 1-12
  
  -- Spending authority
  spending_authority spending_authority NOT NULL,
  
  -- Status
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_level (level),
  INDEX idx_parent (parent_budget_id),
  INDEX idx_agent (agent_id),
  INDEX idx_period (fiscal_year, quarter, month)
);

CREATE TABLE budget.spending_log (
  id BIGSERIAL PRIMARY KEY,
  spending_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What was spent
  budget_id UUID NOT NULL REFERENCES budget.budget_allocations(budget_id),
  expense_type VARCHAR(100),
  description TEXT,
  
  -- Amount
  amount DECIMAL(15, 2) NOT NULL,
  currency VARCHAR(3) DEFAULT 'USD',
  
  -- Who authorized
  authorized_by_user UUID REFERENCES core.users(id),
  authorized_by_agent UUID,
  
  -- Timing
  incurred_at TIMESTAMP NOT NULL DEFAULT NOW(),
  recorded_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  -- Justification
  justification TEXT,
  
  INDEX idx_budget (budget_id),
  INDEX idx_incurred_at (incurred_at DESC),
  INDEX idx_amount (amount DESC)
);

CREATE TABLE budget.budget_alerts (
  id BIGSERIAL PRIMARY KEY,
  alert_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What triggered
  budget_id UUID NOT NULL REFERENCES budget.budget_allocations(budget_id),
  threshold_percent INT, -- 50, 80, 100
  
  -- Alert details
  current_spent DECIMAL(15, 2),
  budget_total DECIMAL(15, 2),
  percent_spent DECIMAL(5, 2),
  
  -- Notification
  alerted_at TIMESTAMP NOT NULL DEFAULT NOW(),
  acknowledged_at TIMESTAMP,
  acknowledged_by_user UUID REFERENCES core.users(id),
  
  INDEX idx_budget (budget_id),
  INDEX idx_threshold (threshold_percent),
  INDEX idx_acknowledged (acknowledged_at)
);

-- ============================================================================
-- DIMENSION 19: AUDIT TRAIL & CHANGE LOG
-- ============================================================================

CREATE TABLE compliance.change_log (
  id BIGSERIAL PRIMARY KEY,
  change_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What changed
  entity_id UUID NOT NULL,
  entity_type entity_type NOT NULL,
  field_name VARCHAR(100) NOT NULL,
  
  -- Old vs New
  old_value TEXT,
  new_value TEXT,
  
  -- Who changed it
  changed_by_agent UUID,
  changed_by_user UUID REFERENCES core.users(id),
  
  -- Why
  reason VARCHAR(500),
  change_type VARCHAR(50), -- 'CREATE', 'UPDATE', 'DELETE', 'STATE_CHANGE'
  
  -- Impact
  affected_systems TEXT[], -- Which systems were affected
  
  -- Timing
  changed_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  INDEX idx_entity (entity_id, entity_type),
  INDEX idx_changed_by (changed_by_agent, changed_by_user),
  INDEX idx_changed_at (changed_at DESC),
  INDEX idx_field (field_name)
);

-- ============================================================================
-- DIMENSION 20: DISASTER RECOVERY (Backups & Snapshots)
-- ============================================================================

CREATE TABLE core.backup_log (
  id BIGSERIAL PRIMARY KEY,
  backup_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Backup info
  backup_type VARCHAR(50), -- 'HOURLY', 'DAILY', 'WEEKLY', 'EMERGENCY'
  backup_location VARCHAR(500) NOT NULL,
  backup_size_gb DECIMAL(10, 2),
  
  -- Encryption
  encryption_key_id UUID,
  is_encrypted BOOLEAN DEFAULT TRUE,
  
  -- Verification
  is_verified BOOLEAN DEFAULT FALSE,
  verification_timestamp TIMESTAMP,
  restore_test_passed BOOLEAN,
  
  -- Timing
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMP, -- Retention policy
  archived_at TIMESTAMP,
  
  -- Metadata
  notes TEXT,
  
  INDEX idx_type (backup_type),
  INDEX idx_created_at (created_at DESC),
  INDEX idx_verified (is_verified),
  INDEX idx_expires_at (expires_at)
);

-- ============================================================================
-- INITIALIZATION DATA
-- ============================================================================

INSERT INTO core.organizations (id, name, description)
VALUES (uuid_generate_v4(), 'Copilot Company', 'Autonomous AI-powered company operations')
ON CONFLICT (name) DO NOTHING;

INSERT INTO core.users (organization_id, username, email, role)
SELECT 
  id,
  'admin',
  'admin@copilot.company',
  'CEO'
FROM core.organizations
WHERE name = 'Copilot Company'
ON CONFLICT (username) DO NOTHING;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON SCHEMA events IS 'Event Sourcing: Immutable event log for all system changes';
COMMENT ON TABLE events.event_log IS 'Immutable log of all events across the system (Dimension 1)';
COMMENT ON TABLE core.distributed_locks IS 'Distributed locks for preventing concurrent conflicts (Dimension 12)';
COMMENT ON TABLE security.sensitive_data_access_log IS 'Audit trail for sensitive data access (Dimension 14)';
COMMENT ON TABLE budget.budget_allocations IS 'Budget hierarchy for financial control (Dimension 17)';
COMMENT ON TABLE compliance.change_log IS 'Complete audit trail of all changes (Dimension 19)';
COMMENT ON TABLE core.backup_log IS 'Disaster recovery backup tracking (Dimension 20)';

-- ============================================================================
-- STATUS
-- ============================================================================

-- SELECT 'PHASE 1 WEEK 1: CORE TABLES CREATED' as status;

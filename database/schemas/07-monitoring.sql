-- MONITORING & OBSERVABILITY
-- Metrics, anomaly detection, health checks, alerts
-- Version: 1.0

\c copilot_company

SET search_path TO monitoring, core, agents, public;

-- ============================================================================
-- METRICS & BASELINE (Dimension 10, 15)
-- ============================================================================

CREATE TABLE IF NOT EXISTS monitoring.agent_metrics (
  id BIGSERIAL PRIMARY KEY,
  metric_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Agent
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- Metric
  metric_name VARCHAR(255) NOT NULL,
  metric_category VARCHAR(50), -- 'THROUGHPUT', 'QUALITY', 'COST', 'LATENCY'
  
  -- Value
  metric_value DECIMAL(15, 4) NOT NULL,
  metric_unit VARCHAR(50),
  
  -- Time window
  window_start TIMESTAMP NOT NULL,
  window_end TIMESTAMP NOT NULL,
  window_size_seconds INT,
  
  -- Metadata
  is_anomalous BOOLEAN DEFAULT FALSE,
  anomaly_score DECIMAL(5, 2),
  
  recorded_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  INDEX idx_agent (agent_id),
  INDEX idx_metric (metric_name),
  INDEX idx_window (window_start, window_end),
  INDEX idx_anomalous (is_anomalous),
  INDEX idx_recorded_at (recorded_at DESC)
);

CREATE TABLE IF NOT EXISTS monitoring.baseline_metrics (
  id BIGSERIAL PRIMARY KEY,
  baseline_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Agent
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- Metric
  metric_name VARCHAR(255) NOT NULL,
  metric_category VARCHAR(50),
  
  -- Baseline statistics
  p50_value DECIMAL(15, 4),
  p95_value DECIMAL(15, 4),
  p99_value DECIMAL(15, 4),
  mean_value DECIMAL(15, 4),
  std_dev DECIMAL(15, 4),
  min_value DECIMAL(15, 4),
  max_value DECIMAL(15, 4),
  
  -- Sample size
  sample_count INT,
  
  -- Period
  baseline_period_days INT DEFAULT 30,
  baseline_calculated_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  UNIQUE (agent_id, metric_name),
  INDEX idx_agent (agent_id),
  INDEX idx_metric (metric_name)
);

-- ============================================================================
-- ANOMALY DETECTION (Dimension 10)
-- ============================================================================

CREATE TABLE IF NOT EXISTS monitoring.anomalies (
  id BIGSERIAL PRIMARY KEY,
  anomaly_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Agent
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- What's anomalous
  metric_name VARCHAR(255) NOT NULL,
  metric_category VARCHAR(50),
  
  -- Detection
  detection_type VARCHAR(50), -- 'STATISTICAL', 'THRESHOLD', 'ML_MODEL', 'RULE'
  anomaly_score DECIMAL(5, 2), -- 0-100
  
  -- Values
  expected_value DECIMAL(15, 4),
  actual_value DECIMAL(15, 4),
  deviation_percent DECIMAL(10, 2),
  
  -- Severity
  severity VARCHAR(50) DEFAULT 'WARNING', -- INFO, WARNING, CRITICAL
  
  -- Status
  status VARCHAR(50) DEFAULT 'OPEN', -- OPEN, INVESTIGATING, RESOLVED, FALSE_POSITIVE
  
  -- Timeline
  detected_at TIMESTAMP NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMP,
  
  -- Investigation
  investigation_notes TEXT,
  investigated_by_user UUID REFERENCES core.users(id),
  
  -- Action taken
  action_taken VARCHAR(500),
  
  INDEX idx_agent (agent_id),
  INDEX idx_metric (metric_name),
  INDEX idx_severity (severity),
  INDEX idx_status (status),
  INDEX idx_detected_at (detected_at DESC)
);

CREATE TABLE IF NOT EXISTS monitoring.anomaly_rules (
  id BIGSERIAL PRIMARY KEY,
  rule_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Rule definition
  agent_id UUID REFERENCES agents.agent_registry(agent_id),
  metric_name VARCHAR(255) NOT NULL,
  
  -- Thresholds
  operator VARCHAR(50), -- '>', '<', '=', '!=', 'PERCENTAGE_CHANGE'
  threshold_value DECIMAL(15, 4),
  
  -- Sensitivity
  threshold_type VARCHAR(50), -- 'ABSOLUTE', 'PERCENTAGE', 'SIGMA'
  sigma_threshold DECIMAL(5, 2) DEFAULT 2.0,
  
  -- Action
  action_on_trigger VARCHAR(100), -- 'ALERT', 'THROTTLE', 'PAUSE', 'ESCALATE'
  
  -- Status
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_agent (agent_id),
  INDEX idx_metric (metric_name),
  INDEX idx_active (is_active)
);

-- ============================================================================
-- HEALTH CHECKS (Dimension 13)
-- ============================================================================

CREATE TABLE IF NOT EXISTS monitoring.health_checks (
  id BIGSERIAL PRIMARY KEY,
  check_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Agent
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- Check info
  check_type VARCHAR(50), -- 'HEARTBEAT', 'RESPONSE_TIME', 'ERROR_RATE', 'MEMORY'
  check_name VARCHAR(255),
  
  -- Results
  status VARCHAR(50), -- 'HEALTHY', 'DEGRADED', 'UNHEALTHY'
  health_score INT, -- 0-100
  
  -- Metrics
  response_time_ms INT,
  error_rate DECIMAL(5, 2),
  memory_usage_mb DECIMAL(10, 2),
  cpu_percent DECIMAL(5, 2),
  
  -- Checks performed
  checks_performed INT,
  checks_passed INT,
  checks_failed INT,
  
  -- Timestamp
  checked_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  -- Recovery actions
  recovery_action_taken VARCHAR(255),
  recovery_attempted_at TIMESTAMP,
  
  INDEX idx_agent (agent_id),
  INDEX idx_check_type (check_type),
  INDEX idx_status (status),
  INDEX idx_checked_at (checked_at DESC)
);

CREATE TABLE IF NOT EXISTS monitoring.recovery_attempts (
  id BIGSERIAL PRIMARY KEY,
  recovery_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Agent & issue
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  health_check_id UUID REFERENCES monitoring.health_checks(check_id),
  
  -- Recovery
  recovery_type VARCHAR(50), -- 'RESTART', 'CLEAR_CACHE', 'RESTORE_STATE', 'RESET_CONFIG'
  
  -- Result
  was_successful BOOLEAN DEFAULT FALSE,
  
  -- Timing
  attempted_at TIMESTAMP NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMP,
  duration_ms INT,
  
  -- Details
  recovery_log TEXT,
  error_message TEXT,
  
  INDEX idx_agent (agent_id),
  INDEX idx_type (recovery_type),
  INDEX idx_successful (was_successful),
  INDEX idx_attempted_at (attempted_at DESC)
);

-- ============================================================================
-- ALERTS & NOTIFICATIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS monitoring.alerts (
  id BIGSERIAL PRIMARY KEY,
  alert_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What triggered
  anomaly_id UUID REFERENCES monitoring.anomalies(anomaly_id),
  health_check_id UUID REFERENCES monitoring.health_checks(check_id),
  
  -- Alert info
  alert_type VARCHAR(50),
  severity VARCHAR(50), -- CRITICAL, HIGH, MEDIUM, LOW, INFO
  title VARCHAR(255) NOT NULL,
  description TEXT,
  
  -- Notification
  status VARCHAR(50) DEFAULT 'OPEN', -- OPEN, ACKNOWLEDGED, RESOLVED
  acknowledged_at TIMESTAMP,
  acknowledged_by_user UUID REFERENCES core.users(id),
  
  -- Timeline
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMP,
  
  -- Routing
  assigned_to_user UUID REFERENCES core.users(id),
  
  INDEX idx_severity (severity),
  INDEX idx_status (status),
  INDEX idx_created_at (created_at DESC),
  INDEX idx_assigned_to (assigned_to_user)
);

-- ============================================================================
-- COST TRACKING (Related to Dimension 17)
-- ============================================================================

CREATE TABLE IF NOT EXISTS monitoring.cost_per_task (
  id BIGSERIAL PRIMARY KEY,
  cost_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Agent & task
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  task_id UUID NOT NULL,
  
  -- Cost breakdown
  model_cost_usd DECIMAL(10, 4),
  api_cost_usd DECIMAL(10, 4),
  compute_cost_usd DECIMAL(10, 4),
  total_cost_usd DECIMAL(10, 4),
  
  -- Resources
  input_tokens INT,
  output_tokens INT,
  execution_time_seconds DECIMAL(10, 2),
  
  -- Efficiency
  cost_per_token DECIMAL(10, 6),
  cost_per_second DECIMAL(10, 4),
  
  -- Metadata
  task_completed_at TIMESTAMP,
  recorded_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  INDEX idx_agent (agent_id),
  INDEX idx_task (task_id),
  INDEX idx_recorded_at (recorded_at DESC)
);

-- ============================================================================
-- STATUS
-- ============================================================================

-- SELECT 'MONITORING & OBSERVABILITY TABLES CREATED' as status;

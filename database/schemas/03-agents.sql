-- AGENTS & MEMORY SYSTEM
-- Agent management, memory storage, versioning, authentication
-- Version: 1.0

\c copilot_company

SET search_path TO agents, core, security, public;

-- ============================================================================
-- AGENT DEFINITIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS agents.agent_registry (
  id BIGSERIAL PRIMARY KEY,
  agent_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Identity
  name VARCHAR(255) NOT NULL UNIQUE,
  display_name VARCHAR(255),
  description TEXT,
  
  -- Classification
  agent_type VARCHAR(50), -- 'SALES', 'FINANCE', 'HR', 'OPS', etc
  category VARCHAR(50), -- 'SPECIALIST', 'ORCHESTRATOR', 'SUPERVISOR'
  
  -- Status
  status agent_status DEFAULT 'INITIALIZING',
  is_active BOOLEAN DEFAULT TRUE,
  
  -- Version
  current_version VARCHAR(20) DEFAULT '1.0.0',
  
  -- Configuration
  config_json JSONB DEFAULT '{}',
  
 -- Capabilities
  capabilities TEXT[] DEFAULT '{}',
  
  -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  started_at TIMESTAMP,
  last_heartbeat TIMESTAMP,
  
  INDEX idx_name (name),
  INDEX idx_type (agent_type),
  INDEX idx_status (status),
  INDEX idx_active (is_active)
);

CREATE TABLE IF NOT EXISTS agents.agent_versions (
  id BIGSERIAL PRIMARY KEY,
  version_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What agent
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- Version info
  version_number VARCHAR(20) NOT NULL,
  semantic_version VARCHAR(20), -- v1.0.0, v1.1.0, etc
  
  -- Deployment info
  deployment_status VARCHAR(50), -- 'BLUE', 'GREEN', 'CANARY', 'ROLLED_BACK'
  deployment_percent INT DEFAULT 100,
  
  -- Configuration
  system_prompt TEXT,
  model_id VARCHAR(100),
  model_parameters JSONB,
  
  -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  deployed_at TIMESTAMP,
  rolled_back_at TIMESTAMP,
  created_by_user UUID REFERENCES core.users(id),
  
  -- Quality
  test_pass_rate DECIMAL(5, 2),
  baseline_metrics JSONB,
  
  UNIQUE (agent_id, version_number),
  INDEX idx_agent (agent_id),
  INDEX idx_deployment (deployment_status),
  INDEX idx_created_at (created_at DESC)
);

CREATE TABLE IF NOT EXISTS agents.agent_capabilities (
  id BIGSERIAL PRIMARY KEY,
  capability_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What agent
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- Capability
  capability_name VARCHAR(255) NOT NULL,
  description TEXT,
  category VARCHAR(50),
  
  -- Constraints
  max_tokens INT,
  max_time_seconds INT,
  max_cost_usd DECIMAL(10, 2),
  
  -- Status
  is_enabled BOOLEAN DEFAULT TRUE,
  
  INDEX idx_agent (agent_id),
  INDEX idx_name (capability_name),
  INDEX idx_enabled (is_enabled)
);

-- ============================================================================
-- AGENT MEMORY SYSTEM (4 LEVELS)
-- ============================================================================

-- Level 1: Personal Memory (This session)
CREATE TABLE IF NOT EXISTS agents.personal_memory (
  id BIGSERIAL PRIMARY KEY,
  memory_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What agent
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- Session
  session_id UUID NOT NULL,
  
  -- Memory
  key VARCHAR(255) NOT NULL,
  value TEXT NOT NULL,
  data_type VARCHAR(50), -- 'STRING', 'JSON', 'VECTOR'
  
  -- Embedding for semantic search
  embedding_vector VECTOR(1536), -- For semantic search
  
  -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  accessed_at TIMESTAMP DEFAULT NOW(),
  expires_at TIMESTAMP,
  
  INDEX idx_agent_session (agent_id, session_id),
  INDEX idx_key (key),
  INDEX idx_expires_at (expires_at)
);

-- Level 2: Persistent Memory (Long-term learning)
CREATE TABLE IF NOT EXISTS agents.persistent_memory (
  id BIGSERIAL PRIMARY KEY,
  memory_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- What agent
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- Classification
  memory_type VARCHAR(50), -- 'PATTERN', 'RULE', 'PREFERENCE', 'MISTAKE'
  category VARCHAR(100),
  
  -- The memory
  key VARCHAR(255) NOT NULL,
  value TEXT NOT NULL,
  confidence DECIMAL(3, 2), -- 0.0 - 1.0
  
  -- Context
  context JSONB,
  related_entities UUID[],
  
 -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  last_used_at TIMESTAMP,
  usage_count INT DEFAULT 0,
  
  UNIQUE (agent_id, memory_type, key),
  INDEX idx_agent (agent_id),
  INDEX idx_type (memory_type),
  INDEX idx_category (category),
  INDEX idx_last_used (last_used_at DESC)
);

-- Level 3: Company Memory (Shared knowledge)
CREATE TABLE IF NOT EXISTS agents.company_memory (
  id BIGSERIAL PRIMARY KEY,
  memory_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Classification
  memory_type VARCHAR(50), -- 'CUSTOMER_INSIGHT', 'MARKET_TREND', 'PROCESS', 'POLICY'
  category VARCHAR(100),
  
  -- The memory
  key VARCHAR(255) NOT NULL UNIQUE,
  value TEXT NOT NULL,
  confidence DECIMAL(3, 2),
  
  -- Sharing
  visible_to_agents UUID[] DEFAULT '{}',
  created_by_agent UUID,
  
  -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_type (memory_type),
  INDEX idx_category (category),
  INDEX idx_created_by_agent (created_by_agent)
);

-- Level 4: Project Memory (Context-specific)
CREATE TABLE IF NOT EXISTS agents.project_memory (
  id BIGSERIAL PRIMARY KEY,
  memory_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Project scope
  project_id UUID NOT NULL,
  agent_id UUID REFERENCES agents.agent_registry(agent_id),
  
  -- Memory
  key VARCHAR(255) NOT NULL,
  value TEXT NOT NULL,
  
  -- Context
  context_data JSONB,
  related_entities UUID[],
  
  -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  UNIQUE (project_id, key),
  INDEX idx_project (project_id),
  INDEX idx_agent (agent_id),
  INDEX idx_updated_at (updated_at DESC)
);

-- ============================================================================
-- AGENT AUTHENTICATION (Dimension 9)
-- ============================================================================

CREATE TABLE IF NOT EXISTS security.agent_credentials (
  id BIGSERIAL PRIMARY KEY,
  credential_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Which agent
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  
  -- Keys
  public_key_pem TEXT NOT NULL,
  private_key_pem_encrypted TEXT NOT NULL, -- AES-256 encrypted
  encryption_key_id UUID,
  
  -- Certificate
  certificate_pem TEXT,
  valid_from TIMESTAMP NOT NULL DEFAULT NOW(),
  valid_until TIMESTAMP NOT NULL DEFAULT (NOW() + INTERVAL '365 days'),
  
  -- Status
  is_active BOOLEAN DEFAULT TRUE,
  is_revoked BOOLEAN DEFAULT FALSE,
  revoked_at TIMESTAMP,
  revocation_reason VARCHAR(500),
  
  -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  rotated_at TIMESTAMP,
  
  INDEX idx_agent (agent_id),
  INDEX idx_active (is_active),
  INDEX idx_valid (valid_until)
);

CREATE TABLE IF NOT EXISTS security.agent_message_signatures (
  id BIGSERIAL PRIMARY KEY,
  signature_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Message
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  message_id UUID NOT NULL,
  
  -- Signature
  signature_algorithm VARCHAR(50), -- 'RSA-2048', 'ECDSA'
  signature_value VARCHAR(2000) NOT NULL,
  
  -- Verification
  is_verified BOOLEAN DEFAULT FALSE,
  verified_at TIMESTAMP,
  verification_error TEXT,
  
  -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_agent (agent_id),
  INDEX idx_message (message_id),
  INDEX idx_verified (is_verified)
);

CREATE TABLE IF NOT EXISTS security.agent_nonces (
  id BIGSERIAL PRIMARY KEY,
  nonce_id UUID UNIQUE NOT NULL DEFAULT uuid_generate_v4(),
  
  -- Agent & message
  agent_id UUID NOT NULL REFERENCES agents.agent_registry(agent_id),
  message_id UUID NOT NULL,
  
  -- Nonce
  nonce_value VARCHAR(500) NOT NULL UNIQUE,
  used_at TIMESTAMP DEFAULT NOW(),
  
  -- Expiration (prevent replay for 5 minutes)
  expires_at TIMESTAMP NOT NULL DEFAULT (NOW() + INTERVAL '5 minutes'),
  
  INDEX idx_agent (agent_id),
  INDEX idx_expires_at (expires_at),
  INDEX idx_used_at (used_at DESC)
);

-- ============================================================================
-- STATUS
-- ============================================================================

-- SELECT 'AGENTS & MEMORY SYSTEM TABLES CREATED' as status;

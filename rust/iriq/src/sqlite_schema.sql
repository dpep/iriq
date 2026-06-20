CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);
CREATE TABLE IF NOT EXISTS host_counts (
  host  TEXT PRIMARY KEY,
  count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS path_length_counts (
  length INTEGER PRIMARY KEY,
  count  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS raw_shape_counts (
  shape TEXT PRIMARY KEY,
  count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS fingerprint_counts (
  shape TEXT PRIMARY KEY,
  count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS position_stats (
  host    TEXT NOT NULL,
  scope   TEXT NOT NULL,
  locator TEXT NOT NULL,
  total   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (host, scope, locator)
);
CREATE TABLE IF NOT EXISTS position_values (
  host    TEXT NOT NULL,
  scope   TEXT NOT NULL,
  locator TEXT NOT NULL,
  value   TEXT NOT NULL,
  count   INTEGER NOT NULL,
  PRIMARY KEY (host, scope, locator, value)
);
CREATE TABLE IF NOT EXISTS position_types (
  host    TEXT NOT NULL,
  scope   TEXT NOT NULL,
  locator TEXT NOT NULL,
  type    TEXT NOT NULL,
  count   INTEGER NOT NULL,
  PRIMARY KEY (host, scope, locator, type)
);
CREATE TABLE IF NOT EXISTS clusters (
  key    TEXT PRIMARY KEY,
  host   TEXT,
  scheme TEXT,
  shape  TEXT,
  count  INTEGER NOT NULL DEFAULT 0,
  ord    INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS cluster_examples (
  cluster_key TEXT NOT NULL,
  position    INTEGER NOT NULL,
  canonical   TEXT NOT NULL,
  PRIMARY KEY (cluster_key, position)
);
CREATE TABLE IF NOT EXISTS cluster_segments (
  cluster_key TEXT NOT NULL,
  position    INTEGER NOT NULL,
  value       TEXT NOT NULL,
  count       INTEGER NOT NULL,
  PRIMARY KEY (cluster_key, position, value)
);
CREATE TABLE IF NOT EXISTS cluster_params (
  cluster_key TEXT NOT NULL,
  name        TEXT NOT NULL,
  total       INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (cluster_key, name)
);
CREATE TABLE IF NOT EXISTS cluster_param_values (
  cluster_key TEXT NOT NULL,
  name        TEXT NOT NULL,
  value       TEXT NOT NULL,
  count       INTEGER NOT NULL,
  PRIMARY KEY (cluster_key, name, value)
);
CREATE TABLE IF NOT EXISTS cluster_param_types (
  cluster_key TEXT NOT NULL,
  name        TEXT NOT NULL,
  type        TEXT NOT NULL,
  count       INTEGER NOT NULL,
  PRIMARY KEY (cluster_key, name, type)
);
CREATE TABLE IF NOT EXISTS observed_iris (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  canonical TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS activated_recognizers (
  prefix      TEXT PRIMARY KEY,
  type        TEXT NOT NULL,
  specificity REAL NOT NULL DEFAULT 1.0
);

-- D1 "probie". Apply with: wrangler d1 execute probie --file schema.sql (add --remote for the deployed one)

-- the show's chat: every message the agent answered, and its on-chain attempt when it called pay
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,            -- unix ms
  ip_hash TEXT NOT NULL,          -- salted HMAC of the visitor's IP, never the IP
  text TEXT NOT NULL,             -- the visitor's message, at most 500 chars
  reply TEXT NOT NULL,            -- '' when the model declined or said nothing
  tool INTEGER NOT NULL,          -- 1 when the agent called pay
  to_addr TEXT,
  amount REAL,                    -- USDG
  tx TEXT,                        -- set only when a transaction was sent
  reason INTEGER,                 -- the Strike reason code
  strikes INTEGER,                -- the permit's strike count after this one
  mode TEXT NOT NULL              -- claude | mock
);
CREATE INDEX IF NOT EXISTS messages_tx ON messages (id) WHERE tx IS NOT NULL AND reason IS NOT NULL;

-- the board, from the cron indexer
CREATE TABLE IF NOT EXISTS permits (
  permit TEXT PRIMARY KEY,
  safe TEXT NOT NULL,
  agent TEXT NOT NULL,
  start_level INTEGER NOT NULL,
  block INTEGER NOT NULL,
  tx TEXT NOT NULL,
  ok INTEGER NOT NULL,            -- 1 = passes the board rules (real SafeProxy 1.4.1 on a 1.4.1 singleton)
  level INTEGER,                  -- from status(), refreshed every run
  clean_days INTEGER,
  strikes INTEGER,
  frozen INTEGER,
  status_at INTEGER,              -- unix s of the last status() read
  last_ts INTEGER                 -- unix s of the last event (created, Paid, Strike, LevelChanged)
);

-- payments backed by a USDG Transfer(safe, payee, amount) in the same transaction as the Paid event
CREATE TABLE IF NOT EXISTS payments (
  tx TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  permit TEXT NOT NULL,
  payee TEXT NOT NULL,
  amount INTEGER NOT NULL,        -- USDG base units (6 decimals)
  ts INTEGER NOT NULL,
  PRIMARY KEY (tx, log_index)
);
CREATE INDEX IF NOT EXISTS payments_permit ON payments (permit);

CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL); -- 'cursor' = the last indexed block

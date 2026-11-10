-- Expose the legacy MySQL tables to PostgreSQL. Three foreign servers point
-- at the same MySQL database, one schema each, so the benchmark can compare
-- mysql_fdw's two performance knobs separately:
--
--   legacy           defaults: no row estimates (every foreign table is
--                    planned as 1000 rows), 100 rows per network fetch
--   legacy_fetch     fetch_size 10000: same plans, 100x fewer round trips
--   legacy_estimate  use_remote_estimate: the planner asks MySQL's EXPLAIN
--                    for row counts, which changes the plans
--
-- All set character_set: the default ('auto') makes libmysqlclient derive
-- it from the PostgreSQL server's locale, which is C here, so the connection
-- silently falls back to latin1 and non-ASCII text (João, Müller...) gets
-- mangled, in results and in pushed-down WHERE clauses alike.
--
-- Run with: psql -v mysql_port=... -v mysql_user=... -v mysql_password=...

CREATE EXTENSION mysql_fdw;

CREATE SERVER mysql_legacy
  FOREIGN DATA WRAPPER mysql_fdw
  OPTIONS (host '127.0.0.1', port :'mysql_port', character_set 'utf8mb4');

CREATE SERVER mysql_legacy_fetch
  FOREIGN DATA WRAPPER mysql_fdw
  OPTIONS (host '127.0.0.1', port :'mysql_port', character_set 'utf8mb4', fetch_size '10000');

CREATE SERVER mysql_legacy_estimate
  FOREIGN DATA WRAPPER mysql_fdw
  OPTIONS (host '127.0.0.1', port :'mysql_port', character_set 'utf8mb4', use_remote_estimate 'true');

CREATE USER MAPPING FOR CURRENT_USER SERVER mysql_legacy
  OPTIONS (username :'mysql_user', password :'mysql_password');
CREATE USER MAPPING FOR CURRENT_USER SERVER mysql_legacy_fetch
  OPTIONS (username :'mysql_user', password :'mysql_password');
CREATE USER MAPPING FOR CURRENT_USER SERVER mysql_legacy_estimate
  OPTIONS (username :'mysql_user', password :'mysql_password');

CREATE SCHEMA legacy;
CREATE SCHEMA legacy_fetch;
CREATE SCHEMA legacy_estimate;
IMPORT FOREIGN SCHEMA bookstore FROM SERVER mysql_legacy INTO legacy;
IMPORT FOREIGN SCHEMA bookstore FROM SERVER mysql_legacy_fetch INTO legacy_fetch;
IMPORT FOREIGN SCHEMA bookstore FROM SERVER mysql_legacy_estimate INTO legacy_estimate;

-- What the application connects with during the migration: migrated tables
-- first, everything else falls through to MySQL.
ALTER DATABASE bookstore SET search_path = app, legacy, public;

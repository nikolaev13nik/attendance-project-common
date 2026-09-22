#!/bin/bash
# Runs ONCE, inside the Postgres container, on first startup with an empty data
# directory. The postgres image executes every .sh and .sql file it finds in
# /docker-entrypoint-initdb.d/ in alphabetical order.
#
# Design: ONE database ("attendance") with ONE SCHEMA PER SERVICE, and one
# database user per service granted rights on only its own schema.
#   - cross-schema queries work for a superuser (handy in DBeaver)
#   - each service still cannot touch the other service's tables

set -e   # abort immediately if any command fails, so a broken init is loud

# --- 1. the database itself -------------------------------------------------
# "$POSTGRES_USER" is provided by the image from docker-compose.yml.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<EOSQL
CREATE DATABASE attendance;
EOSQL

# --- 2. schemas, users and grants inside that database ----------------------
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname attendance <<EOSQL

-- one namespace per service; table names can never collide
CREATE SCHEMA accounting;
CREATE SCHEMA timetracking;

-- one login per service (passwords come from .env via docker-compose.yml)
CREATE USER accounting_user   WITH PASSWORD '$ACCOUNTING_DB_PASSWORD';
CREATE USER timetracking_user WITH PASSWORD '$TIMETRACKING_DB_PASSWORD';

-- both may open a connection to the shared database...
GRANT CONNECT ON DATABASE attendance TO accounting_user, timetracking_user;

-- ...but each may only use and create inside its OWN schema.
-- No GRANT on the other schema = permission denied, enforced by Postgres.
GRANT USAGE, CREATE ON SCHEMA accounting   TO accounting_user;
GRANT USAGE, CREATE ON SCHEMA timetracking TO timetracking_user;

-- default search_path per user: unqualified CREATE TABLE lands in the right
-- schema even if the JDBC URL forgets to say so. Belt and braces.
ALTER ROLE accounting_user   SET search_path = accounting;
ALTER ROLE timetracking_user SET search_path = timetracking;

EOSQL

echo "init-db.sh: database 'attendance' ready with schemas accounting + timetracking"

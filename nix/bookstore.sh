# Local MySQL + PostgreSQL for the bookstore strangler-fig PoC.
#
#   MySQL 8.4    bookstore     7 legacy tables, still owned by the monolith
#                monolith      all 10 tables: baseline from before the migration
#   PostgreSQL   app              3 tables already migrated (reviews, inventory, shipments)
#                legacy           the 7 MySQL tables, as mysql_fdw foreign tables
#                legacy_fetch     same, through a server with fetch_size 10000
#                legacy_estimate  same, through a server with use_remote_estimate
#                native           all 10 tables: baseline for after the migration
#
# Data, sockets and logs live in .data/ at the repository root.

usage() {
  cat <<EOF
Usage: bookstore <command>

Commands:
  up               Start MySQL and PostgreSQL, seeding them on first run
  down             Stop both servers
  seed             Regenerate the mock data and reload both servers
  bench [args]     Run the benchmark (see: bookstore bench --help)
  psql [args]      PostgreSQL shell on the bookstore database
  mysql [args]     MySQL shell (as root) on the bookstore database
  status           Show server state and seeded scale
  logs <mysql|pg>  Follow a server log
  clean            Stop both servers and delete .data
  env              Print the PG*/MYSQL_* exports (use: eval "\$(bookstore env)")

Environment:
  BOOKSTORE_SCALE       Data volume multiplier used by seed (default 1, ~3.2M rows)
  BOOKSTORE_MYSQL_PORT  MySQL port (default 3316)
  BOOKSTORE_PG_PORT     PostgreSQL port (default 5436)
EOF
}

cmd="${1:-help}"
if [[ "$cmd" =~ ^(help|-h|--help)$ ]]; then
  usage
  exit 0
fi
shift || true

root_dir="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ ! -f "$root_dir/sql/seed/generate.sql" ]]; then
  echo "bookstore: run this from inside the pg-mysql-fdw repository" >&2
  exit 1
fi

data_dir="$root_dir/.data"
mysql_dir="$data_dir/mysql"
pg_dir="$data_dir/pg"
tsv_dir="$data_dir/tsv"
seeded_file="$data_dir/seeded"

scale="${BOOKSTORE_SCALE:-1}"
mysql_port="${BOOKSTORE_MYSQL_PORT:-3316}"
pg_port="${BOOKSTORE_PG_PORT:-5436}"

mysql_socket="$mysql_dir/mysqld.sock"
mysql_pid_file="$mysql_dir/mysqld.pid"
mysql_log="$mysql_dir/mysqld.err"
pg_data="$pg_dir/data"
pg_log="$pg_dir/postgres.log"

# TCP account used by mysql_fdw and the benchmark; root is socket-only.
mysql_user=bookstore
mysql_password=bookstore

legacy_tables=(publishers authors books book_authors customers orders order_items)
migrated_tables=(reviews inventory shipments)

export PGHOST="$pg_dir"
export PGPORT="$pg_port"
export PGUSER=postgres
export PGDATABASE=bookstore

mysql_args=(
  --datadir="$mysql_dir/data"
  --socket="$mysql_socket"
  --pid-file="$mysql_pid_file"
  --log-error="$mysql_log"
  --bind-address=127.0.0.1
  --port="$mysql_port"
  --mysqlx=OFF
  # libmysqlclient (mysql_fdw) negotiates TLS whenever the server offers it,
  # PyMySQL (the benchmark's direct MySQL client) does not. Keep both on
  # plain TCP so the comparison measures the FDW and not the encryption.
  --tls-version=
  # Without TLS, caching_sha2_password can't send the password.
  --mysql-native-password=ON
  --skip-log-bin
  --local-infile=ON
  # Small dev tuning, roughly matching what postgresql.conf gets below
  --innodb-buffer-pool-size=1G
  --innodb-flush-log-at-trx-commit=2
  --sort-buffer-size=8M
  --join-buffer-size=16M
  --tmp-table-size=256M
  --max-heap-table-size=256M
)

mysql_root() {
  mysql --no-defaults --user=root --socket="$mysql_socket" "$@"
}

pg_sql() {
  psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 "$@"
}

port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

mysql_running() {
  [[ -f "$mysql_pid_file" ]] && kill -0 "$(cat "$mysql_pid_file")" 2>/dev/null
}

pg_running() {
  [[ -d "$pg_data" ]] && pg_ctl --pgdata="$pg_data" status >/dev/null 2>&1
}

start_mysql() {
  if mysql_running; then
    echo "MySQL already running on 127.0.0.1:$mysql_port"
    return 0
  fi
  if port_in_use "$mysql_port"; then
    echo "bookstore: port $mysql_port is taken, set BOOKSTORE_MYSQL_PORT" >&2
    exit 1
  fi

  mkdir -p "$mysql_dir"
  local fresh=0
  if [[ ! -d "$mysql_dir/data" ]]; then
    fresh=1
    echo "Initializing MySQL data directory at $mysql_dir/data"
    mysqld --no-defaults --initialize-insecure \
      --datadir="$mysql_dir/data" \
      --log-error="$mysql_dir/initialize.err" \
      || { cat "$mysql_dir/initialize.err" >&2; exit 1; }
  fi

  echo "Starting MySQL on 127.0.0.1:$mysql_port"
  setsid mysqld --no-defaults "${mysql_args[@]}" </dev/null >/dev/null 2>&1 &

  for _ in $(seq 1 60); do
    if mysqladmin --no-defaults --user=root --socket="$mysql_socket" ping >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ! mysql_running; then
    echo "MySQL did not start, see $mysql_log:" >&2
    tail -n 30 "$mysql_log" >&2
    exit 1
  fi

  if [[ "$fresh" == 1 ]]; then
    mysql_root <<SQL
CREATE USER '$mysql_user'@'%' IDENTIFIED WITH mysql_native_password BY '$mysql_password';
GRANT ALL PRIVILEGES ON bookstore.* TO '$mysql_user'@'%';
GRANT ALL PRIVILEGES ON monolith.* TO '$mysql_user'@'%';
SQL
  fi
}

start_pg() {
  if pg_running; then
    echo "PostgreSQL already running on 127.0.0.1:$pg_port"
    return 0
  fi
  if port_in_use "$pg_port"; then
    echo "bookstore: port $pg_port is taken, set BOOKSTORE_PG_PORT" >&2
    exit 1
  fi

  mkdir -p "$pg_dir"
  if [[ ! -d "$pg_data" ]]; then
    echo "Initializing PostgreSQL cluster at $pg_data"
    initdb --pgdata="$pg_data" \
      --username=postgres \
      --auth=trust \
      --no-locale \
      --encoding=UTF8 >/dev/null
    cat >>"$pg_data/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
shared_buffers = 1GB
work_mem = 64MB
maintenance_work_mem = 512MB
effective_cache_size = 4GB
random_page_cost = 1.1
max_wal_size = 4GB
EOF
  fi

  echo "Starting PostgreSQL on 127.0.0.1:$pg_port"
  # Port and socket dir on the command line, so the env vars win over the
  # values the cluster was created with.
  pg_ctl --pgdata="$pg_data" -o "-p $pg_port -k $pg_dir" -l "$pg_log" -w start >/dev/null
}

stop_mysql() {
  if mysql_running; then
    local pid
    pid="$(cat "$mysql_pid_file")"
    echo "Stopping MySQL"
    kill "$pid"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.5; done
  fi
}

stop_pg() {
  if pg_running; then
    echo "Stopping PostgreSQL"
    pg_ctl --pgdata="$pg_data" -m fast -w stop >/dev/null
  fi
}

load_mysql() {
  local db="$1"
  shift
  for table in "$@"; do
    mysql_root --local-infile=1 "$db" \
      -e "LOAD DATA LOCAL INFILE '$tsv_dir/$table.tsv' INTO TABLE $table CHARACTER SET utf8mb4"
  done
}

seed() {
  local sql="$root_dir/sql"

  # 1. PostgreSQL generates the data once, into native.* (all 10 tables) and
  #    app.* (the 3 migrated ones), so every scenario sees identical rows.
  echo "Generating mock data in PostgreSQL (scale $scale)"
  PGOPTIONS="-c client_min_messages=warning" dropdb --if-exists --force bookstore
  createdb bookstore
  pg_sql -f "$sql/pg/schema.sql"
  pg_sql -v scale="$scale" -f "$sql/seed/generate.sql"

  # 2. Ship it to MySQL. COPY's text format is LOAD DATA's default format.
  echo "Exporting to $tsv_dir"
  rm -rf "$tsv_dir"
  mkdir -p "$tsv_dir"
  for table in "${legacy_tables[@]}" "${migrated_tables[@]}"; do
    pg_sql -c "\\copy native.$table TO '$tsv_dir/$table.tsv'"
  done

  echo "Loading MySQL databases bookstore (7 legacy tables) and monolith (all 10)"
  mysql_root -e "
    DROP DATABASE IF EXISTS bookstore;
    DROP DATABASE IF EXISTS monolith;
    CREATE DATABASE bookstore;
    CREATE DATABASE monolith;"
  mysql_root bookstore <"$sql/mysql/legacy_tables.sql"
  mysql_root monolith <"$sql/mysql/legacy_tables.sql"
  mysql_root monolith <"$sql/mysql/migrated_tables.sql"
  load_mysql bookstore "${legacy_tables[@]}"
  load_mysql monolith "${legacy_tables[@]}" "${migrated_tables[@]}"

  # 3. Indexes after the bulk load. With foreign_key_checks on, InnoDB would
  #    rebuild every table to add the foreign keys.
  echo "Building indexes"
  mysql_root --init-command="SET SESSION foreign_key_checks = 0" bookstore <"$sql/mysql/legacy_indexes.sql"
  mysql_root --init-command="SET SESSION foreign_key_checks = 0" monolith <"$sql/mysql/legacy_indexes.sql"
  mysql_root --init-command="SET SESSION foreign_key_checks = 0" monolith <"$sql/mysql/migrated_indexes.sql"
  pg_sql -f "$sql/pg/indexes.sql"

  echo "Analyzing"
  for db in bookstore monolith; do
    mysql_root --silent "$db" -e "ANALYZE TABLE $(IFS=,; echo "${legacy_tables[*]}")" >/dev/null
  done
  mysql_root --silent monolith -e "ANALYZE TABLE $(IFS=,; echo "${migrated_tables[*]}")" >/dev/null
  pg_sql -c "VACUUM ANALYZE"

  # 4. Point PostgreSQL at the legacy MySQL tables.
  echo "Importing the legacy schema through mysql_fdw"
  pg_sql \
    -v mysql_port="$mysql_port" \
    -v mysql_user="$mysql_user" \
    -v mysql_password="$mysql_password" \
    -f "$sql/pg/fdw.sql"

  echo "$scale" >"$seeded_file"
  echo "Seeded (scale $scale)"
}

case "$cmd" in
  up)
    start_mysql
    start_pg
    if [[ ! -f "$seeded_file" ]]; then
      seed
    fi
    echo "Ready. MySQL: 127.0.0.1:$mysql_port  PostgreSQL: 127.0.0.1:$pg_port"
    ;;
  down)
    stop_pg
    stop_mysql
    ;;
  seed)
    start_mysql
    start_pg
    seed
    ;;
  bench)
    if ! mysql_running || ! pg_running || [[ ! -f "$seeded_file" ]]; then
      echo "bookstore: run 'bookstore up' first" >&2
      exit 1
    fi
    python3 "$root_dir/bench/bench.py" \
      --mysql-port "$mysql_port" \
      --mysql-user "$mysql_user" \
      --mysql-password "$mysql_password" \
      --scale "$(cat "$seeded_file")" \
      "$@"
    ;;
  psql)
    exec psql "$@"
    ;;
  mysql)
    mysql_root bookstore "$@"
    ;;
  status)
    if mysql_running; then echo "MySQL:      running on 127.0.0.1:$mysql_port"; else echo "MySQL:      stopped"; fi
    if pg_running; then echo "PostgreSQL: running on 127.0.0.1:$pg_port"; else echo "PostgreSQL: stopped"; fi
    if [[ -f "$seeded_file" ]]; then echo "Seeded:     scale $(cat "$seeded_file")"; else echo "Seeded:     no"; fi
    ;;
  logs)
    case "${1:-}" in
      mysql) tail -n 100 -F "$mysql_log" ;;
      pg) tail -n 100 -F "$pg_log" ;;
      *) echo "Usage: bookstore logs <mysql|pg>" >&2; exit 1 ;;
    esac
    ;;
  clean)
    stop_pg
    stop_mysql
    echo "Removing $data_dir"
    rm -rf "$data_dir"
    ;;
  env)
    cat <<EOF
export PGHOST="$pg_dir"
export PGPORT="$pg_port"
export PGUSER=postgres
export PGDATABASE=bookstore
export MYSQL_UNIX_PORT="$mysql_socket"
export BOOKSTORE_PG_URL="postgres://postgres@127.0.0.1:$pg_port/bookstore"
export BOOKSTORE_MYSQL_URL="mysql://$mysql_user:$mysql_password@127.0.0.1:$mysql_port/bookstore"
EOF
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

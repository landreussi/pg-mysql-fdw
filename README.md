# Bookstore strangler fig: do cross-database joins through mysql_fdw slow queries down?

A bookstore runs on a MySQL monolith and is moving to PostgreSQL one table at a
time (strangler fig). Mid-migration, 7 of its 10 tables (70%) still live in
MySQL and 3 (30%) already live in PostgreSQL. The application talks to
PostgreSQL only, and reaches the legacy tables through
[mysql_fdw](https://github.com/EnterpriseDB/mysql_fdw) foreign tables, so a
query can join across both databases.

This PoC answers: **how much slower do those nested cross-database joins get,
compared with the same query before the migration (all MySQL) and after it
(all PostgreSQL)?**

## TL;DR

It depends almost entirely on **where the selective filter is**, because
mysql_fdw can push a whole join to MySQL but can never push join keys coming
from a PostgreSQL table.

| Query shape | fdw vs. MySQL monolith | Why |
|---|---|---|
| OLTP lookups with a constant filter (01, 02) | at most +0.5 ms | Whole legacy join pushed to MySQL, a handful of rows come back |
| Report over legacy tables only (04) | 1.0× | Join + aggregate + ORDER BY + LIMIT pushed: MySQL does all the work |
| Report filtered on legacy, aggregated on PG (03) | **0.4× (faster)** | Only the filtered legacy slice comes over; PostgreSQL aggregates the migrated table better than MySQL did |
| Selective filter on the migrated side only (05, 06) | 1.4× to **26×** | MySQL gets no usable filter: the full legacy join (up to 1.35M rows) is shipped over and filtered in PostgreSQL |
| Same as 06, plus a redundant predicate on a legacy column (07) | 2.4× | MySQL can range-scan again: 156k rows instead of 1.35M |
| Correlated subquery into legacy tables (08) | 3.8× | The correlation is never pushed; best case is one full scan hashed locally |

And the two tuning knobs:

- `fetch_size '10000'` (default 100): a 4-15% win on big transfers here.
  Free to turn on. Matters far more on a real network (see [Caveats](#caveats)).
- `use_remote_estimate 'true'`: **dangerous**. It made 07 13× slower and 08
  time out (>120 s instead of 3.8 s). Don't enable it globally, see
  [why](#4-pushed-down-joins-have-a-constant-cost).

So: mysql_fdw is fine for the OLTP paths and for reports whose filters hit the
legacy side. Reports whose only selective filter is on a migrated table are the
ones that get slow, and they need either a redundant legacy-side predicate,
the filter column duplicated into the legacy side (or the other way round), or
moving the tables that are queried together in the same migration step.

## Results

Final run, scale 1 (~3.2M rows), median of 5 runs after 1 warmup, warm caches,
both servers on the same machine (12 CPUs). Every scenario returned the same
rows for every query.

| Query | MySQL monolith | PG + fdw | PG + fdw, fetch_size | PG + fdw, remote estimate | PG native | fdw ÷ monolith | fdw ÷ native | rows over fdw |
|---|---|---|---|---|---|---|---|---|
| 01_book_page | 0.4 ms | 0.9 ms | 0.9 ms | 1.2 ms | 0.5 ms | 2.5× | 1.9× | 1 |
| 02_order_history | 3.6 ms | 3.4 ms | 3.8 ms | 3.7 ms | 2.9 ms | 0.9× | 1.2× | 50 |
| 03_top_rated_scifi | 845 ms | 316 ms | 327 ms | 252 ms | 88.8 ms | 0.4× | 3.6× | 107,005 |
| 04_bestselling_authors | 425 ms | 436 ms | 418 ms | 409 ms | 78.5 ms | 1.0× | 5.6× | 10 |
| 05_restock_report | 309 ms | 418 ms | 398 ms | 423 ms | 75.4 ms | 1.4× | 5.5× | 136,710 |
| 06_revenue_by_publisher | 122 ms | 3217 ms | 2884 ms | 4102 ms | 30.2 ms | 26.4× | 106.7× | 1,349,856 |
| 07_revenue_by_publisher_hinted | 121 ms | 289 ms | 248 ms | 3831 ms | 77.6 ms | 2.4× | 3.7× | 156,336 |
| 08_verified_reviews | 979 ms | 3757 ms | 3597 ms | timeout (>120 s) | 1010 ms | 3.8× | 3.7× | 1,349,862 |

*rows over fdw*: rows PostgreSQL pulled from MySQL in one execution of the
default `PG + fdw` scenario. `bookstore bench` regenerates this table, a
per-query breakdown with the remote SQL mysql_fdw generated, and every
EXPLAIN ANALYZE plan in `results/<timestamp>/`.

## Quick start

Needs Nix with flakes. No Docker: both servers run as local processes with
their data in `.data/`.

```sh
nix develop        # dev shell, prints the commands below
bookstore up       # start MySQL 8.4 + PostgreSQL 18, seed on first run (~1.5 min)
bookstore bench    # run the benchmark (~7 min), writes results/<timestamp>/report.md
bookstore down     # stop both
```

Without the dev shell: `nix run . -- up`, `nix run . -- bench`, ...

| Command | |
|---|---|
| `bookstore up` | Start both servers, seed on first run |
| `bookstore down` | Stop both servers |
| `bookstore seed` | Regenerate the data and reload both servers (`BOOKSTORE_SCALE=5 bookstore seed` for 5×) |
| `bookstore bench [--runs N] [--only 06] [--timeout S] [--no-explain] [--print-plans]` | Run the benchmark |
| `bookstore psql` / `bookstore mysql` | Shells. In the dev shell plain `psql` and `mysql -uroot` work too |
| `bookstore status` / `logs mysql\|pg` / `clean` | |

Ports default to 3316 (MySQL) and 5436 (PostgreSQL); override with
`BOOKSTORE_MYSQL_PORT` / `BOOKSTORE_PG_PORT`.

To poke at a query by hand:

```sql
-- bookstore psql: the database's search_path is the mid-migration view, app + legacy
EXPLAIN (ANALYZE, VERBOSE) SELECT ...;   -- look for "Remote query:" and rows= on Foreign Scan
SET search_path = app, legacy_fetch;     -- or legacy_estimate, or native
```

### On GitHub Actions

`.github/workflows/bench.yml` runs `bookstore up` + `bookstore bench` on a
GitHub-hosted runner, on every push to the default branch that touches the
benchmark, or by hand from the Actions tab (*Run workflow*, with optional
scale, runs and query filter). The report goes to:

- the run's **job summary**, rendered on the run page
- a `bench-results` **artifact**: report.md, results.json and every plan
- the **`bench-results` branch** (default branch, full runs only): its
  README.md is the latest report, `runs/<timestamp>/` keeps every run

Shared runners are noisy and smaller than the machine behind the numbers
above, so compare ratios across runs rather than absolute times.

## The setup

### Tables

| Table | Lives in | Rows (scale 1) | Notes |
|---|---|---|---|
| publishers | MySQL | 500 | |
| authors | MySQL | 20,000 | names include non-ASCII (João, Müller) |
| books | MySQL | 100,000 | skewed towards big publishers |
| book_authors | MySQL | 129,998 | 1 to 3 authors per book |
| customers | MySQL | 100,000 | |
| orders | MySQL | 500,000 | volume grows month over month, 2019 to 2026-10-31 |
| order_items | MySQL | 1,249,862 | bestsellers dominate |
| reviews | PostgreSQL | 397,518 | ~40% written by people who bought the book |
| inventory | PostgreSQL | 250,366 | 4 warehouses, ~17% of rows below reorder level |
| shipments | PostgreSQL | 483,670 | delivered at most 13 days after the order |

Both sides carry the same primary keys, unique keys, secondary indexes and
(within one server) foreign keys. The migrated tables can't have foreign keys
to the legacy ones: that integrity is the application's problem until the rest
moves.

### Scenarios

The same SQL text runs in every scenario over the same rows (generated once in
PostgreSQL and shipped to MySQL as TSV). Only name resolution changes:

| Scenario | Where | Tables |
|---|---|---|
| MySQL monolith | MySQL database `monolith` | all 10 in MySQL: before the migration |
| PG + fdw | PostgreSQL, `search_path = app, legacy` | 3 in `app`, 7 foreign tables in `legacy` (mysql_fdw defaults): **during** |
| PG + fdw, fetch_size | `app, legacy_fetch` | same, foreign server with `fetch_size '10000'` |
| PG + fdw, remote estimate | `app, legacy_estimate` | same, foreign server with `use_remote_estimate 'true'` |
| PG native | PostgreSQL schema `native` | all 10 in PostgreSQL: after the migration |

The live legacy database (`bookstore` in MySQL) holds only the 7 legacy tables;
`monolith` is a separate pre-migration copy with all 10.

### Queries

`bench/queries/*.sql`, each starting with a comment explaining it.

| Query | Shape |
|---|---|
| 01_book_page | 4-way legacy join on a book id + 3 subqueries on migrated tables |
| 02_order_history | 4-way legacy join on a customer email, LEFT JOIN migrated shipments, ORDER BY + LIMIT |
| 03_top_rated_scifi | aggregate migrated reviews, join 4 legacy tables filtered by genre |
| 04_bestselling_authors | 4-way legacy join + aggregate over a date range, nothing migrated |
| 05_restock_report | low-stock migrated inventory, join legacy books/publishers and a legacy sales aggregate |
| 06_revenue_by_publisher | migrated shipments (the only filter) joined to 4 legacy tables |
| 07_revenue_by_publisher_hinted | 06 plus a redundant `orders.ordered_at` predicate |
| 08_verified_reviews | correlated `EXISTS` from migrated reviews into legacy orders + order_items |

## What mysql_fdw does with a join

Read off the plans in `results/*/plans/` and mysql_fdw 2.9.3's source.

### 1. Joins between foreign tables are pushed down whole

Any tree of INNER/LEFT/RIGHT joins between foreign tables of the same server
becomes one MySQL query, along with the WHERE clauses, aggregates, ORDER BY and
LIMIT it can translate. Query 04 reaches MySQL as a single
`SELECT ... SUM(...) ... GROUP BY ... ORDER BY ... LIMIT 10` and returns 10
rows, which is why it costs the same as on the monolith. Semi/anti joins
(`EXISTS`, `NOT EXISTS`, `IN (subquery)`) and FULL joins are never pushed.

### 2. A local table can't drive a lookup into a foreign one

This is the big one. mysql_fdw only ever offers the planner unparameterized
scans of a foreign relation. postgres_fdw can run "for each local row, fetch the
matching remote rows" (a parameterized path), mysql_fdw can't. So when the
selective filter is on a PostgreSQL table, MySQL never learns which keys are
wanted and sends everything that matches its own constant filters:

- 05: 10k low-stock inventory rows need their book titles, so all 100k
  `books ⋈ publishers` rows come over.
- 06: 8k shipments delivered in September need their order lines, so the full
  `orders ⋈ order_items` (1.25M rows) and `books ⋈ publishers` (100k) come
  over. 26× the monolith, 107× native.

The fix in 07 is to give MySQL a range it can use: shipments are delivered at
most 13 days after the order, so `o.ordered_at >= '2026-08-15'` changes nothing
in the result and cuts the transfer to 156k rows (26× down to 2.4×).

### 3. Correlated predicates are evaluated locally

In 08 the subquery's `o.customer_id = r.customer_id` shows up as a local
`Filter`, not in the remote query. With default estimates the planner hashes
the subquery: one full `orders ⋈ order_items` scan (1.25M rows), then hash
lookups, 3.8×. With `use_remote_estimate` it rescans both tables for every one
of the 7k reviews, and does not finish within the 120 s timeout.

### 4. Pushed-down joins have a constant cost

Every pushed-down join is costed at `15..35` no matter how many rows it
returns, and with default options every foreign table is estimated at 1000
rows (`ANALYZE` on a foreign table collects nothing). Wrong, but consistently
wrong: everything foreign looks small, so the planner pushes joins and hashes
their output, which is usually what you want.

`use_remote_estimate` asks MySQL's EXPLAIN for base-table row counts while
planning, but the join cost stays the constant. Now a scan of `orders` costs
what it really costs while `order_items ⋈ books` (1.2M rows) still looks
almost free, so the planner picks the huge unfiltered pushed join over the
selective one (07: 156k rows → 1.24M rows, 13× slower), or a nested loop of
remote rescans (08). It also adds remote EXPLAIN round trips to every
planning. It's a server-level option, so it can't be enabled per table.

### 5. Results arrive `fetch_size` rows at a time

mysql_fdw reads through a server-side cursor, 100 rows per round trip by
default. On localhost a round trip costs ~nothing, so `fetch_size '10000'`
only saves 4-15% on the big transfers; most of the cost of moving 1.35M rows
(~2.4 µs per row) is MySQL materializing the cursor and PostgreSQL converting
every value.

### 6. Set `character_set` on the server

The default `character_set 'auto'` makes libmysqlclient pick the charset from
the PostgreSQL server's locale. Under the C locale that is latin1: names like
João come back as invalid UTF-8 and pushed-down `WHERE first_name = 'João'`
silently matches nothing. `sql/pg/fdw.sql` sets `character_set 'utf8mb4'`.

## Recommendations for the migration

1. **Check the remote side of every cross-database query**:
   `EXPLAIN (ANALYZE, VERBOSE)` shows each `Remote query:` and how many rows
   its Foreign Scan returned. Thousands of rows feeding a query that returns
   20 is the warning sign.
2. **Give MySQL a filter it can use.** Redundant predicates derived from
   business rules (07), or duplicating a filter column on the legacy side
   (e.g. a `delivered_at` copy on `orders`) turn 06-style queries back into
   04-style ones.
3. **Migrate together what is filtered together.** `shipments` moved while
   `orders` stayed is exactly what makes 06 slow; moving tables by bounded
   context, with the tables their reports filter on, avoids most of it.
4. **Set `fetch_size` high (e.g. 10000) and `character_set 'utf8mb4'`** on the
   foreign server. Leave `use_remote_estimate` off.
5. **Avoid correlated subqueries into foreign tables**; rewrite as joins or
   pre-aggregate on the legacy side.
6. For heavy reports that can't be fixed this way, replicate the legacy tables
   into PostgreSQL (logical replication / CDC) instead of reading them live.

## Caveats

- **Localhost.** Both servers share one machine, so a round trip costs a few
  µs. On a real network every `fetch_size` batch is one round trip: 06 moves
  1.35M rows in 13,500 batches by default, which at 0.5 ms RTT adds ~7 s on top
  of the 3.2 s measured here; with `fetch_size '10000'` it is 135 batches and
  ~0.07 s. OLTP queries add a few round trips each (prepare, execute, fetch).
- Warm caches, a single client, no concurrent writes.
- TLS is off on MySQL so mysql_fdw and the benchmark's direct MySQL client
  both use plain TCP (`nix/bookstore.sh`); with TLS the FDW pays for
  encryption on every transferred row.
- MySQL monolith vs. PG native is not a MySQL vs. PostgreSQL shootout. Both get
  similar memory settings, but no per-query tuning; PostgreSQL's plans (hash
  joins, better aggregation) win most reports here.
- Scale 1 is ~3.2M rows (~550 MB in the MySQL monolith). The FDW transfer cost
  grows with the remote rows a query needs, so 05/06/08 get worse with
  `BOOKSTORE_SCALE`, while 01/02/04 shouldn't move much.

## Layout

```
flake.nix               MySQL 8.4, PostgreSQL 18 + mysql_fdw, the bookstore CLI, dev shell
nix/mysql_fdw.nix       mysql_fdw 2.9.3 (not in nixpkgs)
nix/bookstore.sh        the CLI: server lifecycle, seeding, bench
sql/mysql/              legacy (7) and pre-migration (3) table DDL + indexes
sql/pg/schema.sql       app (3 migrated) and native (all 10) schemas
sql/pg/indexes.sql      same indexes as MySQL
sql/pg/fdw.sql          foreign servers + IMPORT FOREIGN SCHEMA
sql/seed/generate.sql   deterministic mock data
bench/queries/          the 8 benchmark queries
bench/bench.py          benchmark harness and report
.github/workflows/      the benchmark on GitHub Actions
```

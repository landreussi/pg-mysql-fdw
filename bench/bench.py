"""Time every bench/queries/*.sql in every scenario and write a report.

All scenarios run the very same SQL text over the very same rows; only name
resolution changes:

  mysql_monolith   MySQL, USE monolith                  all 10 tables in MySQL (before)
  pg_fdw           PostgreSQL, app + legacy             3 local tables, 7 via mysql_fdw (during)
  pg_fdw_fetch     PostgreSQL, app + legacy_fetch       same, fetch_size 10000
  pg_fdw_estimate  PostgreSQL, app + legacy_estimate    same, use_remote_estimate
  pg_native        PostgreSQL, native                   all 10 tables in PostgreSQL (after)

Run through `bookstore bench`, which passes the connection settings.
"""

import argparse
import datetime as dt
import json
import os
import platform
import re
import statistics
import time
from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path

import psycopg
import pymysql

ROOT = Path(__file__).resolve().parent.parent
DESCRIPTION = "Time every bench/queries/*.sql in every scenario and write a report."

# MySQL's "Query execution was interrupted, maximum statement execution time exceeded"
MYSQL_TIMEOUT = 3024


@dataclass
class Scenario:
    name: str
    label: str
    engine: str  # "mysql" or "pg"
    namespace: str  # MySQL database, or PostgreSQL search_path
    description: str


SCENARIOS = [
    Scenario("mysql_monolith", "MySQL monolith", "mysql", "monolith",
             "all 10 tables in MySQL (before the migration)"),
    Scenario("pg_fdw", "PG + fdw", "pg", "app, legacy",
             "3 tables in PostgreSQL, 7 in MySQL through mysql_fdw, default options (during)"),
    Scenario("pg_fdw_fetch", "PG + fdw, fetch_size", "pg", "app, legacy_fetch",
             "same, foreign server with `fetch_size '10000'`"),
    Scenario("pg_fdw_estimate", "PG + fdw, remote estimate", "pg", "app, legacy_estimate",
             "same, foreign server with `use_remote_estimate 'true'`"),
    Scenario("pg_native", "PG native", "pg", "native",
             "all 10 tables in PostgreSQL (after the migration)"),
]
FDW_SCENARIOS = [s.name for s in SCENARIOS if s.name.startswith("pg_fdw")]


@dataclass
class Query:
    name: str
    title: str
    description: str
    sql: str


@dataclass
class Measurement:
    timings_ms: list = field(default_factory=list)
    error: str | None = None
    timed_out: bool = False
    rows: list | None = None
    plan: str | None = None
    # pg_fdw* only, from EXPLAIN ANALYZE
    fdw_rows: int | None = None
    fdw_executions: int | None = None
    remote_queries: list = field(default_factory=list)

    @property
    def median_ms(self):
        return statistics.median(self.timings_ms) if self.timings_ms else None


def load_queries(pattern):
    queries = []
    for path in sorted((ROOT / "bench" / "queries").glob("*.sql")):
        if pattern and pattern not in path.stem:
            continue
        lines = path.read_text().strip().splitlines()
        header = [line[2:].strip() for line in lines if line.startswith("--")]
        body = "\n".join(line for line in lines if not line.startswith("--"))
        queries.append(Query(path.stem, header[0], " ".join(header[1:]), body.strip().rstrip(";")))
    return queries


class Connection:
    """The same few operations over psycopg and PyMySQL."""

    def __init__(self, scenario, args):
        self.scenario = scenario
        if scenario.engine == "pg":
            # PGHOST, PGPORT, ... come from the environment
            self.conn = psycopg.connect(autocommit=True)
            self.execute(f"SET search_path = {scenario.namespace}")
            self.execute(f"SET statement_timeout = '{args.timeout}s'")
        else:
            self.conn = pymysql.connect(
                host="127.0.0.1",
                port=args.mysql_port,
                user=args.mysql_user,
                password=args.mysql_password,
                database=scenario.namespace,
                autocommit=True,
            )
            self.execute(f"SET SESSION max_execution_time = {args.timeout * 1000}")

    def execute(self, sql):
        with self.conn.cursor() as cur:
            cur.execute(sql)
            return cur.fetchall() if cur.description else []

    def explain(self, sql, analyze=True):
        if self.scenario.engine == "pg":
            prefix = "EXPLAIN (ANALYZE, VERBOSE, BUFFERS)" if analyze else "EXPLAIN (VERBOSE)"
        else:
            prefix = "EXPLAIN ANALYZE" if analyze else "EXPLAIN FORMAT=TREE"
        return "\n".join(row[0] for row in self.execute(f"{prefix} {sql}"))

    def close(self):
        self.conn.close()


def normalize(rows):
    """Comparable form of a result set, across drivers and engines."""

    def value(v):
        if isinstance(v, (int, float, Decimal)) and not isinstance(v, bool):
            return f"{Decimal(v):.2f}"
        if isinstance(v, (dt.datetime, dt.date)):
            return v.isoformat()
        return v

    return sorted((tuple(value(v) for v in row) for row in rows), key=repr)


FOREIGN_SCAN = re.compile(r"Foreign Scan.*\(actual time=\S+ rows=([\d.]+) loops=(\d+)\)")
REMOTE_QUERY = re.compile(r"Remote query: (.*)")


def parse_fdw_plan(plan, m):
    rows = executions = 0
    for match in FOREIGN_SCAN.finditer(plan):
        loops = int(match.group(2))
        rows += round(float(match.group(1)) * loops)
        executions += loops
    m.fdw_rows = rows
    m.fdw_executions = executions
    m.remote_queries = REMOTE_QUERY.findall(plan)


def is_timeout(e):
    if isinstance(e, psycopg.errors.QueryCanceled):
        return True
    return isinstance(e, pymysql.MySQLError) and bool(e.args) and e.args[0] == MYSQL_TIMEOUT


def run(query, scenario, args, plans_dir):
    m = Measurement()
    plan_file = plans_dir / f"{query.name}.{scenario.name}.txt"
    conn = Connection(scenario, args)
    try:
        for _ in range(args.warmup):
            m.rows = normalize(conn.execute(query.sql))
        started = time.perf_counter()
        while len(m.timings_ms) < args.runs:
            t0 = time.perf_counter()
            rows = conn.execute(query.sql)
            m.timings_ms.append((time.perf_counter() - t0) * 1000)
            m.rows = normalize(rows)
            if time.perf_counter() - started > args.budget:
                break
        if not args.no_explain:
            plan = conn.explain(query.sql)
            m.plan = plan
            plan_file.write_text(plan + "\n")
            if scenario.name in FDW_SCENARIOS:
                parse_fdw_plan(plan, m)
    except (psycopg.Error, pymysql.MySQLError) as e:
        m.timed_out = is_timeout(e)
        m.error = str(e).strip().splitlines()[0]
        if not args.no_explain:
            # Keep the plan that was too slow to EXPLAIN ANALYZE
            try:
                plan = conn.explain(query.sql, analyze=False)
                m.plan = f"Not executed: {m.error}\n\n{plan}"
                plan_file.write_text(m.plan + "\n")
                if scenario.name in FDW_SCENARIOS:
                    m.remote_queries = REMOTE_QUERY.findall(plan)
            except (psycopg.Error, pymysql.MySQLError):
                pass
    finally:
        conn.close()
    return m


def fmt_ms(ms):
    if ms is None:
        return "—"
    if ms >= 10_000:
        return f"{ms / 1000:.1f} s"
    if ms >= 100:
        return f"{ms:.0f} ms"
    return f"{ms:.1f} ms"


def fmt_ratio(a, b):
    if a is None or b is None or b == 0:
        return "—"
    return f"{a / b:.1f}×"


def fmt_cell(m, args):
    if m.timings_ms:
        return fmt_ms(m.median_ms)
    if m.timed_out:
        return f"timeout (>{args.timeout} s)"
    return f"error: {m.error}"


def server_info(args):
    pg = Connection(SCENARIOS[1], args)
    my = Connection(SCENARIOS[0], args)
    try:
        fdw_version = pg.execute("SELECT public.mysql_fdw_version()")[0][0]  # 20903 = 2.9.3
        return {
            "postgresql": pg.execute("SHOW server_version")[0][0],
            "mysql_fdw": f"{fdw_version // 10000}.{fdw_version // 100 % 100}.{fdw_version % 100}",
            "mysql": my.execute("SELECT VERSION()")[0][0],
            "scale": args.scale,
            "cpu_count": os.cpu_count(),
            "platform": platform.platform(),
        }
    finally:
        pg.close()
        my.close()


def same_result(results):
    reference = next((m.rows for m in results.values() if m.rows is not None), None)
    return all(m.rows == reference for m in results.values() if m.rows is not None)


def summary_table(queries, results, args):
    header = (
        ["Query"]
        + [s.label for s in SCENARIOS]
        + ["fdw ÷ monolith", "fdw ÷ native", "rows over fdw", "same result"]
    )
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    for q in queries:
        r = results[q.name]
        fdw = r["pg_fdw"]
        cells = (
            [q.name]
            + [fmt_cell(r[s.name], args) for s in SCENARIOS]
            + [
                fmt_ratio(fdw.median_ms, r["mysql_monolith"].median_ms),
                fmt_ratio(fdw.median_ms, r["pg_native"].median_ms),
                "—" if fdw.fdw_rows is None else f"{fdw.fdw_rows:,}",
                "yes" if same_result(r) else "**NO**",
            ]
        )
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)


def write_report(out_dir, info, args, queries, results):
    md = [
        "# mysql_fdw strangler-fig benchmark",
        "",
        f"- Run: {info['started']}",
        f"- PostgreSQL {info['postgresql']}, mysql_fdw {info['mysql_fdw']}, MySQL {info['mysql']}",
        f"- Scale {info['scale']}, {info['cpu_count']} CPUs, {info['platform']}",
        f"- Median of up to {args.runs} runs after {args.warmup} warmup "
        f"(stops early after {args.budget:g} s per cell), client-side wall clock",
        "",
        "Scenarios:",
        "",
        *[f"- **{s.label}**: {s.description}" for s in SCENARIOS],
        "",
        "*fdw* columns compare the default `PG + fdw` scenario. *rows over fdw*: rows PostgreSQL pulled "
        "from MySQL in one execution, summed over every Foreign Scan in EXPLAIN ANALYZE.",
        "",
        summary_table(queries, results, args),
        "",
    ]
    for q in queries:
        r = results[q.name]
        md += [f"## {q.name}", "", f"**{q.title}**", "", q.description, "", "```sql", q.sql, "```", ""]
        md += ["| Scenario | median | min | max | runs | rows over fdw | remote executions |", "|---|---|---|---|---|---|---|"]
        for s in SCENARIOS:
            m = r[s.name]
            fdw = ["", ""] if m.fdw_rows is None else [f"{m.fdw_rows:,}", f"{m.fdw_executions:,}"]
            if m.timings_ms:
                cells = [fmt_ms(m.median_ms), fmt_ms(min(m.timings_ms)), fmt_ms(max(m.timings_ms)), str(len(m.timings_ms))]
            else:
                cells = [fmt_cell(m, args), "", "", ""]
            md.append("| " + " | ".join([s.label, *cells, *fdw]) + " |")
        md.append("")
        for name in FDW_SCENARIOS:
            if r[name].remote_queries:
                # Collapsed: long, and usually identical across the fdw scenarios
                md += [f"<details><summary>Remote queries, <code>{name}</code></summary>", "",
                       "```sql", *r[name].remote_queries, "```", "", "</details>", ""]
        plans = [f"[{s.label}](plans/{q.name}.{s.name}.txt)" for s in SCENARIOS if r[s.name].plan]
        if plans:
            md += ["Plans: " + " · ".join(plans), ""]
    (out_dir / "report.md").write_text("\n".join(md))

    data = {
        "info": info,
        "queries": {
            q.name: {
                "title": q.title,
                "same_result": same_result(results[q.name]),
                "scenarios": {
                    s.name: {
                        "timings_ms": m.timings_ms,
                        "median_ms": m.median_ms,
                        "error": m.error,
                        "timed_out": m.timed_out,
                        "row_count": None if m.rows is None else len(m.rows),
                        "fdw_rows": m.fdw_rows,
                        "fdw_executions": m.fdw_executions,
                    }
                    for s in SCENARIOS
                    for m in [results[q.name][s.name]]
                },
            }
            for q in queries
        },
    }
    (out_dir / "results.json").write_text(json.dumps(data, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(prog="bookstore bench", description=DESCRIPTION)
    parser.add_argument("--runs", type=int, default=5, help="timed runs per query and scenario (default 5)")
    parser.add_argument("--warmup", type=int, default=1, help="untimed runs first (default 1)")
    parser.add_argument("--budget", type=float, default=30, help="stop timing a cell after this many seconds (default 30)")
    parser.add_argument("--timeout", type=int, default=120, help="statement timeout in seconds (default 120)")
    parser.add_argument("--only", help="only run queries whose file name contains this")
    parser.add_argument("--no-explain", action="store_true", help="skip EXPLAIN ANALYZE (and the fdw row counts)")
    parser.add_argument("--print-plans", action="store_true", help="also print each query plan to stdout")
    parser.add_argument("--out", type=Path, help="output directory (default results/<timestamp>)")
    parser.add_argument("--mysql-port", type=int, required=True, help=argparse.SUPPRESS)
    parser.add_argument("--mysql-user", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--mysql-password", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--scale", default="?", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.print_plans and args.no_explain:
        parser.error("--print-plans needs EXPLAIN, drop --no-explain")

    started = dt.datetime.now().replace(microsecond=0)
    out_dir = args.out or ROOT / "results" / started.strftime("%Y%m%d-%H%M%S")
    plans_dir = out_dir / "plans"
    plans_dir.mkdir(parents=True, exist_ok=True)

    info = server_info(args) | {"started": started.isoformat(sep=" ")}
    queries = load_queries(args.only)
    results = {}
    for q in queries:
        print(f"{q.name}: {q.title}", flush=True)
        results[q.name] = {}
        for s in SCENARIOS:
            m = run(q, s, args, plans_dir)
            results[q.name][s.name] = m
            extra = "" if m.fdw_rows is None else f"  ({m.fdw_rows:,} rows over fdw)"
            print(f"  {s.label:<26} {fmt_cell(m, args)}{extra}", flush=True)
            if args.print_plans and m.plan:
                print("\n".join("    " + line for line in m.plan.splitlines()), flush=True)

    write_report(out_dir, info, args, queries, results)
    latest = ROOT / "results" / "latest"
    if out_dir.parent == latest.parent:
        latest.unlink(missing_ok=True)
        latest.symlink_to(out_dir.name)
    print()
    print(summary_table(queries, results, args))
    print()
    print(f"Report: {out_dir / 'report.md'}")


if __name__ == "__main__":
    main()

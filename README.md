> [Workflow run #1](https://github.com/landreussi/pg-mysql-fdw/actions/runs/42892118157) on commit [`b532baa`](https://github.com/landreussi/pg-mysql-fdw/commit/b532baabeadb61ac1c5fd819f53f8d88e73ce7ae) (`master`), GitHub-hosted runner. Shared VMs are noisy and differ from the machine behind the README's numbers: compare ratios, not absolute times.

# mysql_fdw strangler-fig benchmark

- Run: 2026-11-10 20:09:11
- PostgreSQL 18.6, mysql_fdw 2.9.3, MySQL 8.4.11
- Scale 1, 4 CPUs, Linux-7.0.0-1019-azure-x86_64-with-glibc2.44
- Median of up to 5 runs after 1 warmup (stops early after 30 s per cell), client-side wall clock

Scenarios:

- **MySQL monolith**: all 10 tables in MySQL (before the migration)
- **PG + fdw**: 3 tables in PostgreSQL, 7 in MySQL through mysql_fdw, default options (during)
- **PG + fdw, fetch_size**: same, foreign server with `fetch_size '10000'`
- **PG + fdw, remote estimate**: same, foreign server with `use_remote_estimate 'true'`
- **PG native**: all 10 tables in PostgreSQL (after the migration)

*fdw* columns compare the default `PG + fdw` scenario. *rows over fdw*: rows PostgreSQL pulled from MySQL in one execution, summed over every Foreign Scan in EXPLAIN ANALYZE.

| Query | MySQL monolith | PG + fdw | PG + fdw, fetch_size | PG + fdw, remote estimate | PG native | fdw ÷ monolith | fdw ÷ native | rows over fdw | same result |
|---|---|---|---|---|---|---|---|---|---|
| 01_book_page | 0.5 ms | 1.1 ms | 1.3 ms | 1.7 ms | 0.6 ms | 2.5× | 2.0× | 1 | yes |
| 02_order_history | 4.2 ms | 3.7 ms | 3.7 ms | 4.2 ms | 2.9 ms | 0.9× | 1.3× | 50 | yes |
| 03_top_rated_scifi | 808 ms | 367 ms | 319 ms | 280 ms | 72.5 ms | 0.5× | 5.1× | 107,005 | yes |
| 04_bestselling_authors | 464 ms | 480 ms | 480 ms | 479 ms | 84.7 ms | 1.0× | 5.7× | 10 | yes |
| 05_restock_report | 339 ms | 516 ms | 444 ms | 513 ms | 114 ms | 1.5× | 4.5× | 136,710 | yes |
| 06_revenue_by_publisher | 144 ms | 3480 ms | 2804 ms | 4961 ms | 41.0 ms | 24.2× | 84.9× | 1,349,856 | yes |
| 07_revenue_by_publisher_hinted | 141 ms | 399 ms | 317 ms | 4657 ms | 67.1 ms | 2.8× | 5.9× | 156,336 | yes |
| 08_verified_reviews | 931 ms | 4408 ms | 3761 ms | timeout (>120 s) | 981 ms | 4.7× | 4.5× | 1,349,862 | yes |

## 01_book_page

**Book page: one book with its publisher and authors (legacy) plus rating summary and stock (migrated)**

OLTP. Every table is reached through its primary key or an index on the book id, and the 4-way legacy join carries a constant filter MySQL can use.

```sql
SELECT b.id, b.title, b.price, p.name AS publisher, a.first_name, a.last_name,
       (SELECT ROUND(AVG(r.rating), 2) FROM reviews r WHERE r.book_id = b.id) AS avg_rating,
       (SELECT COUNT(*) FROM reviews r WHERE r.book_id = b.id) AS review_count,
       (SELECT SUM(i.quantity) FROM inventory i WHERE i.book_id = b.id) AS in_stock
FROM books b
JOIN publishers p ON p.id = b.publisher_id
JOIN book_authors ba ON ba.book_id = b.id
JOIN authors a ON a.id = ba.author_id
WHERE b.id = 4242
ORDER BY ba.author_order
```

| Scenario | median | min | max | runs | rows over fdw | remote executions |
|---|---|---|---|---|---|---|
| MySQL monolith | 0.5 ms | 0.4 ms | 0.5 ms | 5 |  |  |
| PG + fdw | 1.1 ms | 1.1 ms | 1.3 ms | 5 | 1 | 1 |
| PG + fdw, fetch_size | 1.3 ms | 1.2 ms | 1.4 ms | 5 | 1 | 1 |
| PG + fdw, remote estimate | 1.7 ms | 1.7 ms | 1.8 ms | 5 | 1 | 1 |
| PG native | 0.6 ms | 0.5 ms | 0.6 ms | 5 |  |  |

<details><summary>Remote queries, <code>pg_fdw</code></summary>

```sql
SELECT r1.`id`, r1.`title`, r1.`price`, r2.`name`, r6.`first_name`, r6.`last_name`, r4.`author_order` FROM (((`bookstore`.`books` r1 INNER JOIN `bookstore`.`publishers` r2 ON (((r1.`publisher_id` = r2.`id`)))) INNER JOIN `bookstore`.`book_authors` r4 ON (TRUE)) INNER JOIN `bookstore`.`authors` r6 ON (((r4.`author_id` = r6.`id`)))) WHERE ((r4.`book_id` = 4242)) AND ((r1.`id` = 4242)) ORDER BY r4.`author_order` IS NULL, r4.`author_order` ASC
```

</details>

<details><summary>Remote queries, <code>pg_fdw_fetch</code></summary>

```sql
SELECT r1.`id`, r1.`title`, r1.`price`, r2.`name`, r6.`first_name`, r6.`last_name`, r4.`author_order` FROM (((`bookstore`.`books` r1 INNER JOIN `bookstore`.`publishers` r2 ON (((r1.`publisher_id` = r2.`id`)))) INNER JOIN `bookstore`.`book_authors` r4 ON (TRUE)) INNER JOIN `bookstore`.`authors` r6 ON (((r4.`author_id` = r6.`id`)))) WHERE ((r4.`book_id` = 4242)) AND ((r1.`id` = 4242)) ORDER BY r4.`author_order` IS NULL, r4.`author_order` ASC
```

</details>

<details><summary>Remote queries, <code>pg_fdw_estimate</code></summary>

```sql
SELECT r1.`id`, r1.`title`, r1.`price`, r2.`name`, r6.`first_name`, r6.`last_name`, r4.`author_order` FROM (((`bookstore`.`books` r1 INNER JOIN `bookstore`.`publishers` r2 ON (((r1.`publisher_id` = r2.`id`)))) INNER JOIN `bookstore`.`book_authors` r4 ON (TRUE)) INNER JOIN `bookstore`.`authors` r6 ON (((r4.`author_id` = r6.`id`)))) WHERE ((r4.`book_id` = 4242)) AND ((r1.`id` = 4242)) ORDER BY r4.`author_order` IS NULL, r4.`author_order` ASC
```

</details>

Plans: [MySQL monolith](plans/01_book_page.mysql_monolith.txt) · [PG + fdw](plans/01_book_page.pg_fdw.txt) · [PG + fdw, fetch_size](plans/01_book_page.pg_fdw_fetch.txt) · [PG + fdw, remote estimate](plans/01_book_page.pg_fdw_estimate.txt) · [PG native](plans/01_book_page.pg_native.txt)

## 02_order_history

**Order history page: a customer's latest order lines (legacy) with shipment tracking (migrated)**

OLTP, driven by the customer's email. The 4 legacy tables are joined remotely; the shipments join and the ORDER BY ... LIMIT happen locally.

```sql
SELECT o.id AS order_id, o.ordered_at, o.status, oi.line_no, b.title, oi.quantity, oi.unit_price,
       s.carrier, s.status AS shipment_status, s.delivered_at
FROM customers c
JOIN orders o ON o.customer_id = c.id
JOIN order_items oi ON oi.order_id = o.id
JOIN books b ON b.id = oi.book_id
LEFT JOIN shipments s ON s.order_id = o.id
WHERE c.email = 'customer42@example.com'
ORDER BY o.ordered_at DESC, o.id DESC, oi.line_no
LIMIT 50
```

| Scenario | median | min | max | runs | rows over fdw | remote executions |
|---|---|---|---|---|---|---|
| MySQL monolith | 4.2 ms | 3.8 ms | 4.6 ms | 5 |  |  |
| PG + fdw | 3.7 ms | 3.7 ms | 4.2 ms | 5 | 50 | 1 |
| PG + fdw, fetch_size | 3.7 ms | 3.6 ms | 3.8 ms | 5 | 50 | 1 |
| PG + fdw, remote estimate | 4.2 ms | 4.0 ms | 4.4 ms | 5 | 50 | 1 |
| PG native | 2.9 ms | 2.8 ms | 3.4 ms | 5 |  |  |

<details><summary>Remote queries, <code>pg_fdw</code></summary>

```sql
SELECT r2.`id`, r2.`ordered_at`, r2.`status`, r4.`line_no`, r4.`quantity`, r4.`unit_price`, r6.`title` FROM (((`bookstore`.`customers` r1 INNER JOIN `bookstore`.`orders` r2 ON (((r1.`id` = r2.`customer_id`)))) INNER JOIN `bookstore`.`order_items` r4 ON (((r2.`id` = r4.`order_id`)))) INNER JOIN `bookstore`.`books` r6 ON (((r4.`book_id` = r6.`id`)))) WHERE ((r1.`email` = 'customer42@example.com')) ORDER BY r2.`ordered_at` IS NOT NULL, r2.`ordered_at` DESC, r4.`order_id` IS NOT NULL, r4.`order_id` DESC, r4.`line_no` IS NULL, r4.`line_no` ASC
```

</details>

<details><summary>Remote queries, <code>pg_fdw_fetch</code></summary>

```sql
SELECT r2.`id`, r2.`ordered_at`, r2.`status`, r4.`line_no`, r4.`quantity`, r4.`unit_price`, r6.`title` FROM (((`bookstore`.`customers` r1 INNER JOIN `bookstore`.`orders` r2 ON (((r1.`id` = r2.`customer_id`)))) INNER JOIN `bookstore`.`order_items` r4 ON (((r2.`id` = r4.`order_id`)))) INNER JOIN `bookstore`.`books` r6 ON (((r4.`book_id` = r6.`id`)))) WHERE ((r1.`email` = 'customer42@example.com')) ORDER BY r2.`ordered_at` IS NOT NULL, r2.`ordered_at` DESC, r4.`order_id` IS NOT NULL, r4.`order_id` DESC, r4.`line_no` IS NULL, r4.`line_no` ASC
```

</details>

<details><summary>Remote queries, <code>pg_fdw_estimate</code></summary>

```sql
SELECT r2.`id`, r2.`ordered_at`, r2.`status`, r4.`line_no`, r4.`quantity`, r4.`unit_price`, r6.`title` FROM (((`bookstore`.`customers` r1 INNER JOIN `bookstore`.`orders` r2 ON (((r1.`id` = r2.`customer_id`)))) INNER JOIN `bookstore`.`order_items` r4 ON (((r2.`id` = r4.`order_id`)))) INNER JOIN `bookstore`.`books` r6 ON (((r4.`book_id` = r6.`id`)))) WHERE ((r1.`email` = 'customer42@example.com')) ORDER BY r2.`ordered_at` IS NOT NULL, r2.`ordered_at` DESC, r4.`order_id` IS NOT NULL, r4.`order_id` DESC, r4.`line_no` IS NULL, r4.`line_no` ASC
```

</details>

Plans: [MySQL monolith](plans/02_order_history.mysql_monolith.txt) · [PG + fdw](plans/02_order_history.pg_fdw.txt) · [PG + fdw, fetch_size](plans/02_order_history.pg_fdw_fetch.txt) · [PG + fdw, remote estimate](plans/02_order_history.pg_fdw_estimate.txt) · [PG native](plans/02_order_history.pg_native.txt)

## 03_top_rated_scifi

**Top rated science fiction since 2025: aggregate migrated reviews, then join the legacy catalogue**

Reporting. The genre filter lets MySQL return only the science fiction slice of books + first author + publisher (~7k rows).

```sql
SELECT b.id, b.title, a.last_name AS author, p.name AS publisher, r.review_count, r.avg_rating
FROM (
  SELECT book_id, COUNT(*) AS review_count, ROUND(AVG(rating), 2) AS avg_rating
  FROM reviews
  WHERE created_at >= '2025-01-01'
  GROUP BY book_id
  HAVING COUNT(*) >= 10
) r
JOIN books b ON b.id = r.book_id
JOIN book_authors ba ON ba.book_id = b.id AND ba.author_order = 1
JOIN authors a ON a.id = ba.author_id
JOIN publishers p ON p.id = b.publisher_id
WHERE b.genre = 'Science Fiction'
ORDER BY r.avg_rating DESC, r.review_count DESC, b.id
LIMIT 20
```

| Scenario | median | min | max | runs | rows over fdw | remote executions |
|---|---|---|---|---|---|---|
| MySQL monolith | 808 ms | 795 ms | 812 ms | 5 |  |  |
| PG + fdw | 367 ms | 365 ms | 373 ms | 5 | 107,005 | 2 |
| PG + fdw, fetch_size | 319 ms | 316 ms | 327 ms | 5 | 107,005 | 2 |
| PG + fdw, remote estimate | 280 ms | 274 ms | 290 ms | 5 | 7,300 | 2 |
| PG native | 72.5 ms | 72.4 ms | 78.5 ms | 5 |  |  |

<details><summary>Remote queries, <code>pg_fdw</code></summary>

```sql
SELECT r2.`id`, r2.`title`, r8.`name` FROM (`bookstore`.`books` r2 INNER JOIN `bookstore`.`publishers` r8 ON (((r2.`publisher_id` = r8.`id`)))) WHERE ((r2.`genre` = 'Science Fiction')) ORDER BY r2.`id` IS NULL, r2.`id` ASC
SELECT r4.`book_id`, r6.`last_name` FROM (`bookstore`.`book_authors` r4 INNER JOIN `bookstore`.`authors` r6 ON (((r4.`author_id` = r6.`id`)))) WHERE ((r4.`author_order` = 1)) ORDER BY r4.`book_id` IS NULL, r4.`book_id` ASC
```

</details>

<details><summary>Remote queries, <code>pg_fdw_fetch</code></summary>

```sql
SELECT r2.`id`, r2.`title`, r8.`name` FROM (`bookstore`.`books` r2 INNER JOIN `bookstore`.`publishers` r8 ON (((r2.`publisher_id` = r8.`id`)))) WHERE ((r2.`genre` = 'Science Fiction')) ORDER BY r2.`id` IS NULL, r2.`id` ASC
SELECT r4.`book_id`, r6.`last_name` FROM (`bookstore`.`book_authors` r4 INNER JOIN `bookstore`.`authors` r6 ON (((r4.`author_id` = r6.`id`)))) WHERE ((r4.`author_order` = 1)) ORDER BY r4.`book_id` IS NULL, r4.`book_id` ASC
```

</details>

<details><summary>Remote queries, <code>pg_fdw_estimate</code></summary>

```sql
SELECT r2.`id`, r2.`title`, r8.`name` FROM (`bookstore`.`books` r2 INNER JOIN `bookstore`.`publishers` r8 ON (((r2.`publisher_id` = r8.`id`)))) WHERE ((r2.`genre` = 'Science Fiction')) ORDER BY r2.`id` IS NULL, r2.`id` ASC
SELECT r4.`book_id`, r6.`last_name` FROM (`bookstore`.`book_authors` r4 INNER JOIN `bookstore`.`authors` r6 ON (((r4.`author_id` = r6.`id`)))) WHERE ((r4.`author_order` = 1)) ORDER BY r4.`book_id` IS NULL, r4.`book_id` ASC
```

</details>

Plans: [MySQL monolith](plans/03_top_rated_scifi.mysql_monolith.txt) · [PG + fdw](plans/03_top_rated_scifi.pg_fdw.txt) · [PG + fdw, fetch_size](plans/03_top_rated_scifi.pg_fdw_fetch.txt) · [PG + fdw, remote estimate](plans/03_top_rated_scifi.pg_fdw_estimate.txt) · [PG native](plans/03_top_rated_scifi.pg_native.txt)

## 04_bestselling_authors

**Bestselling authors of Q3 2026: legacy tables only**

Reporting. A 4-way join + aggregate + ORDER BY + LIMIT that touches no migrated table, so mysql_fdw can ship the whole query to MySQL.

```sql
SELECT a.id, a.first_name, a.last_name, SUM(oi.quantity) AS copies_sold
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
JOIN book_authors ba ON ba.book_id = oi.book_id
JOIN authors a ON a.id = ba.author_id
WHERE o.ordered_at >= '2026-07-01' AND o.ordered_at < '2026-10-01'
  AND o.status <> 'cancelled'
GROUP BY a.id, a.first_name, a.last_name
ORDER BY copies_sold DESC, a.id
LIMIT 10
```

| Scenario | median | min | max | runs | rows over fdw | remote executions |
|---|---|---|---|---|---|---|
| MySQL monolith | 464 ms | 460 ms | 471 ms | 5 |  |  |
| PG + fdw | 480 ms | 475 ms | 492 ms | 5 | 10 | 1 |
| PG + fdw, fetch_size | 480 ms | 473 ms | 481 ms | 5 | 10 | 1 |
| PG + fdw, remote estimate | 479 ms | 478 ms | 482 ms | 5 | 10 | 1 |
| PG native | 84.7 ms | 83.6 ms | 85.9 ms | 5 |  |  |

<details><summary>Remote queries, <code>pg_fdw</code></summary>

```sql
SELECT r6.`id`, r6.`first_name`, r6.`last_name`, sum(r2.`quantity`) FROM (((`bookstore`.`orders` r1 INNER JOIN `bookstore`.`order_items` r2 ON (((r1.`id` = r2.`order_id`)))) INNER JOIN `bookstore`.`book_authors` r4 ON (((r2.`book_id` = r4.`book_id`)))) INNER JOIN `bookstore`.`authors` r6 ON (((r4.`author_id` = r6.`id`)))) WHERE ((r1.`ordered_at` >= '2026-07-01 00:00:00')) AND ((r1.`ordered_at` < '2026-10-01 00:00:00')) AND ((r1.`status` <> 'cancelled')) GROUP BY 1, 2, 3 ORDER BY sum(r2.`quantity`) IS NOT NULL, sum(r2.`quantity`) DESC, r6.`id` IS NULL, r6.`id` ASC LIMIT 10
```

</details>

<details><summary>Remote queries, <code>pg_fdw_fetch</code></summary>

```sql
SELECT r6.`id`, r6.`first_name`, r6.`last_name`, sum(r2.`quantity`) FROM (((`bookstore`.`orders` r1 INNER JOIN `bookstore`.`order_items` r2 ON (((r1.`id` = r2.`order_id`)))) INNER JOIN `bookstore`.`book_authors` r4 ON (((r2.`book_id` = r4.`book_id`)))) INNER JOIN `bookstore`.`authors` r6 ON (((r4.`author_id` = r6.`id`)))) WHERE ((r1.`ordered_at` >= '2026-07-01 00:00:00')) AND ((r1.`ordered_at` < '2026-10-01 00:00:00')) AND ((r1.`status` <> 'cancelled')) GROUP BY 1, 2, 3 ORDER BY sum(r2.`quantity`) IS NOT NULL, sum(r2.`quantity`) DESC, r6.`id` IS NULL, r6.`id` ASC LIMIT 10
```

</details>

<details><summary>Remote queries, <code>pg_fdw_estimate</code></summary>

```sql
SELECT r6.`id`, r6.`first_name`, r6.`last_name`, sum(r2.`quantity`) FROM (((`bookstore`.`orders` r1 INNER JOIN `bookstore`.`order_items` r2 ON (((r1.`id` = r2.`order_id`)))) INNER JOIN `bookstore`.`book_authors` r4 ON (((r2.`book_id` = r4.`book_id`)))) INNER JOIN `bookstore`.`authors` r6 ON (((r4.`author_id` = r6.`id`)))) WHERE ((r1.`ordered_at` >= '2026-07-01 00:00:00')) AND ((r1.`ordered_at` < '2026-10-01 00:00:00')) AND ((r1.`status` <> 'cancelled')) GROUP BY 1, 2, 3 ORDER BY sum(r2.`quantity`) IS NOT NULL, sum(r2.`quantity`) DESC, r6.`id` IS NULL, r6.`id` ASC LIMIT 10
```

</details>

Plans: [MySQL monolith](plans/04_bestselling_authors.mysql_monolith.txt) · [PG + fdw](plans/04_bestselling_authors.pg_fdw.txt) · [PG + fdw, fetch_size](plans/04_bestselling_authors.pg_fdw_fetch.txt) · [PG + fdw, remote estimate](plans/04_bestselling_authors.pg_fdw_estimate.txt) · [PG native](plans/04_bestselling_authors.pg_native.txt)

## 05_restock_report

**Restock report: low-stock NYC inventory (migrated) with title, publisher and recent sales (legacy)**

Reporting. The selective filter is on the migrated side (~10k of 250k inventory rows); the legacy side only knows "orders since August".

```sql
SELECT b.id, b.title, p.name AS publisher, i.quantity, i.reorder_level,
       COALESCE(sales.units, 0) AS units_sold
FROM inventory i
JOIN books b ON b.id = i.book_id
JOIN publishers p ON p.id = b.publisher_id
LEFT JOIN (
  SELECT oi.book_id, SUM(oi.quantity) AS units
  FROM order_items oi
  JOIN orders o ON o.id = oi.order_id
  WHERE o.ordered_at >= '2026-08-01'
  GROUP BY oi.book_id
) sales ON sales.book_id = i.book_id
WHERE i.warehouse_code = 'US-NYC' AND i.quantity < i.reorder_level
ORDER BY units_sold DESC, b.id
LIMIT 25
```

| Scenario | median | min | max | runs | rows over fdw | remote executions |
|---|---|---|---|---|---|---|
| MySQL monolith | 339 ms | 335 ms | 344 ms | 5 |  |  |
| PG + fdw | 516 ms | 509 ms | 555 ms | 5 | 136,710 | 2 |
| PG + fdw, fetch_size | 444 ms | 442 ms | 446 ms | 5 | 136,710 | 2 |
| PG + fdw, remote estimate | 513 ms | 509 ms | 514 ms | 5 | 136,710 | 2 |
| PG native | 114 ms | 113 ms | 115 ms | 5 |  |  |

<details><summary>Remote queries, <code>pg_fdw</code></summary>

```sql
SELECT r2.`id`, r2.`title`, r4.`name` FROM (`bookstore`.`books` r2 INNER JOIN `bookstore`.`publishers` r4 ON (((r2.`publisher_id` = r4.`id`)))) ORDER BY r2.`id` IS NULL, r2.`id` ASC
SELECT r1.`book_id`, sum(r1.`quantity`) FROM (`bookstore`.`order_items` r1 INNER JOIN `bookstore`.`orders` r2 ON (((r1.`order_id` = r2.`id`)))) WHERE ((r2.`ordered_at` >= '2026-08-01 00:00:00')) GROUP BY 1
```

</details>

<details><summary>Remote queries, <code>pg_fdw_fetch</code></summary>

```sql
SELECT r2.`id`, r2.`title`, r4.`name` FROM (`bookstore`.`books` r2 INNER JOIN `bookstore`.`publishers` r4 ON (((r2.`publisher_id` = r4.`id`)))) ORDER BY r2.`id` IS NULL, r2.`id` ASC
SELECT r1.`book_id`, sum(r1.`quantity`) FROM (`bookstore`.`order_items` r1 INNER JOIN `bookstore`.`orders` r2 ON (((r1.`order_id` = r2.`id`)))) WHERE ((r2.`ordered_at` >= '2026-08-01 00:00:00')) GROUP BY 1
```

</details>

<details><summary>Remote queries, <code>pg_fdw_estimate</code></summary>

```sql
SELECT r2.`id`, r2.`title`, r4.`name` FROM (`bookstore`.`books` r2 INNER JOIN `bookstore`.`publishers` r4 ON (((r2.`publisher_id` = r4.`id`)))) ORDER BY r2.`id` IS NULL, r2.`id` ASC
SELECT r1.`book_id`, sum(r1.`quantity`) FROM (`bookstore`.`order_items` r1 INNER JOIN `bookstore`.`orders` r2 ON (((r1.`order_id` = r2.`id`)))) WHERE ((r2.`ordered_at` >= '2026-08-01 00:00:00')) GROUP BY 1
```

</details>

Plans: [MySQL monolith](plans/05_restock_report.mysql_monolith.txt) · [PG + fdw](plans/05_restock_report.pg_fdw.txt) · [PG + fdw, fetch_size](plans/05_restock_report.pg_fdw_fetch.txt) · [PG + fdw, remote estimate](plans/05_restock_report.pg_fdw_estimate.txt) · [PG native](plans/05_restock_report.pg_native.txt)

## 06_revenue_by_publisher

**Revenue per publisher for orders delivered in September 2026: filter only on migrated shipments**

Reporting, worst case. The only filter is on shipments, so the 4 legacy tables (orders, order_items, books, publishers) get no WHERE clause at all.

```sql
SELECT p.id, p.name, COUNT(DISTINCT o.id) AS orders, SUM(oi.quantity * oi.unit_price) AS revenue
FROM shipments s
JOIN orders o ON o.id = s.order_id
JOIN order_items oi ON oi.order_id = o.id
JOIN books b ON b.id = oi.book_id
JOIN publishers p ON p.id = b.publisher_id
WHERE s.status = 'delivered'
  AND s.delivered_at >= '2026-09-01' AND s.delivered_at < '2026-10-01'
GROUP BY p.id, p.name
ORDER BY revenue DESC, p.id
LIMIT 15
```

| Scenario | median | min | max | runs | rows over fdw | remote executions |
|---|---|---|---|---|---|---|
| MySQL monolith | 144 ms | 143 ms | 147 ms | 5 |  |  |
| PG + fdw | 3480 ms | 3454 ms | 3493 ms | 5 | 1,349,856 | 2 |
| PG + fdw, fetch_size | 2804 ms | 2793 ms | 2828 ms | 5 | 1,349,856 | 2 |
| PG + fdw, remote estimate | 4961 ms | 4926 ms | 4995 ms | 5 | 1,716,415 | 3 |
| PG native | 41.0 ms | 40.5 ms | 47.1 ms | 5 |  |  |

<details><summary>Remote queries, <code>pg_fdw</code></summary>

```sql
SELECT r6.`id`, r8.`id`, r8.`name` FROM (`bookstore`.`books` r6 INNER JOIN `bookstore`.`publishers` r8 ON (((r6.`publisher_id` = r8.`id`)))) ORDER BY r6.`id` IS NULL, r6.`id` ASC
SELECT r2.`id`, r4.`quantity`, r4.`unit_price`, r4.`order_id`, r4.`book_id` FROM (`bookstore`.`orders` r2 INNER JOIN `bookstore`.`order_items` r4 ON (((r2.`id` = r4.`order_id`)))) ORDER BY r2.`id` IS NULL, r2.`id` ASC
```

</details>

<details><summary>Remote queries, <code>pg_fdw_fetch</code></summary>

```sql
SELECT r6.`id`, r8.`id`, r8.`name` FROM (`bookstore`.`books` r6 INNER JOIN `bookstore`.`publishers` r8 ON (((r6.`publisher_id` = r8.`id`)))) ORDER BY r6.`id` IS NULL, r6.`id` ASC
SELECT r2.`id`, r4.`quantity`, r4.`unit_price`, r4.`order_id`, r4.`book_id` FROM (`bookstore`.`orders` r2 INNER JOIN `bookstore`.`order_items` r4 ON (((r2.`id` = r4.`order_id`)))) ORDER BY r2.`id` IS NULL, r2.`id` ASC
```

</details>

<details><summary>Remote queries, <code>pg_fdw_estimate</code></summary>

```sql
SELECT `id`, `name` FROM `bookstore`.`publishers` ORDER BY `id` IS NULL, `id` ASC
SELECT `id` FROM `bookstore`.`orders` ORDER BY `id` IS NULL, `id` ASC
SELECT r4.`quantity`, r4.`unit_price`, r4.`order_id`, r6.`publisher_id` FROM (`bookstore`.`order_items` r4 INNER JOIN `bookstore`.`books` r6 ON (((r4.`book_id` = r6.`id`)))) ORDER BY r4.`order_id` IS NULL, r4.`order_id` ASC
```

</details>

Plans: [MySQL monolith](plans/06_revenue_by_publisher.mysql_monolith.txt) · [PG + fdw](plans/06_revenue_by_publisher.pg_fdw.txt) · [PG + fdw, fetch_size](plans/06_revenue_by_publisher.pg_fdw_fetch.txt) · [PG + fdw, remote estimate](plans/06_revenue_by_publisher.pg_fdw_estimate.txt) · [PG native](plans/06_revenue_by_publisher.pg_native.txt)

## 07_revenue_by_publisher_hinted

**Same as 06, plus a redundant filter on legacy orders that MySQL can use**

The fix for 06: orders are delivered at most 13 days after they are placed (see sql/seed/generate.sql), so anything delivered in September was ordered after mid-August. Same result, but now the remote side has a range to scan.

```sql
SELECT p.id, p.name, COUNT(DISTINCT o.id) AS orders, SUM(oi.quantity * oi.unit_price) AS revenue
FROM shipments s
JOIN orders o ON o.id = s.order_id
JOIN order_items oi ON oi.order_id = o.id
JOIN books b ON b.id = oi.book_id
JOIN publishers p ON p.id = b.publisher_id
WHERE s.status = 'delivered'
  AND s.delivered_at >= '2026-09-01' AND s.delivered_at < '2026-10-01'
  AND o.ordered_at >= '2026-08-15'
GROUP BY p.id, p.name
ORDER BY revenue DESC, p.id
LIMIT 15
```

| Scenario | median | min | max | runs | rows over fdw | remote executions |
|---|---|---|---|---|---|---|
| MySQL monolith | 141 ms | 141 ms | 142 ms | 5 |  |  |
| PG + fdw | 399 ms | 396 ms | 409 ms | 5 | 156,336 | 2 |
| PG + fdw, fetch_size | 317 ms | 311 ms | 326 ms | 5 | 156,336 | 2 |
| PG + fdw, remote estimate | 4657 ms | 4615 ms | 4715 ms | 5 | 1,238,928 | 3 |
| PG native | 67.1 ms | 64.8 ms | 68.6 ms | 5 |  |  |

<details><summary>Remote queries, <code>pg_fdw</code></summary>

```sql
SELECT r6.`id`, r8.`id`, r8.`name` FROM (`bookstore`.`books` r6 INNER JOIN `bookstore`.`publishers` r8 ON (((r6.`publisher_id` = r8.`id`)))) ORDER BY r6.`id` IS NULL, r6.`id` ASC
SELECT r2.`id`, r4.`quantity`, r4.`unit_price`, r4.`order_id`, r4.`book_id` FROM (`bookstore`.`orders` r2 INNER JOIN `bookstore`.`order_items` r4 ON (((r2.`id` = r4.`order_id`)))) WHERE ((r2.`ordered_at` >= '2026-08-15 00:00:00')) ORDER BY r2.`id` IS NULL, r2.`id` ASC
```

</details>

<details><summary>Remote queries, <code>pg_fdw_fetch</code></summary>

```sql
SELECT r6.`id`, r8.`id`, r8.`name` FROM (`bookstore`.`books` r6 INNER JOIN `bookstore`.`publishers` r8 ON (((r6.`publisher_id` = r8.`id`)))) ORDER BY r6.`id` IS NULL, r6.`id` ASC
SELECT r2.`id`, r4.`quantity`, r4.`unit_price`, r4.`order_id`, r4.`book_id` FROM (`bookstore`.`orders` r2 INNER JOIN `bookstore`.`order_items` r4 ON (((r2.`id` = r4.`order_id`)))) WHERE ((r2.`ordered_at` >= '2026-08-15 00:00:00')) ORDER BY r2.`id` IS NULL, r2.`id` ASC
```

</details>

<details><summary>Remote queries, <code>pg_fdw_estimate</code></summary>

```sql
SELECT `id`, `name` FROM `bookstore`.`publishers` ORDER BY `id` IS NULL, `id` ASC
SELECT r4.`quantity`, r4.`unit_price`, r4.`order_id`, r6.`publisher_id` FROM (`bookstore`.`order_items` r4 INNER JOIN `bookstore`.`books` r6 ON (((r4.`book_id` = r6.`id`)))) ORDER BY r4.`order_id` IS NULL, r4.`order_id` ASC
SELECT `id` FROM `bookstore`.`orders` WHERE ((`ordered_at` >= '2026-08-15 00:00:00')) ORDER BY `id` IS NULL, `id` ASC
```

</details>

Plans: [MySQL monolith](plans/07_revenue_by_publisher_hinted.mysql_monolith.txt) · [PG + fdw](plans/07_revenue_by_publisher_hinted.pg_fdw.txt) · [PG + fdw, fetch_size](plans/07_revenue_by_publisher_hinted.pg_fdw_fetch.txt) · [PG + fdw, remote estimate](plans/07_revenue_by_publisher_hinted.pg_fdw_estimate.txt) · [PG native](plans/07_revenue_by_publisher_hinted.pg_native.txt)

## 08_verified_reviews

**Verified-buyer share of October 2026 reviews per genre: correlated EXISTS from migrated into legacy**

Reporting. For each of ~7k reviews, check whether the reviewer bought the book: a subquery over orders + order_items parameterized by the review.

```sql
SELECT b.genre, COUNT(*) AS reviews,
       SUM(CASE WHEN EXISTS (
             SELECT 1
             FROM orders o
             JOIN order_items oi ON oi.order_id = o.id
             WHERE o.customer_id = r.customer_id AND oi.book_id = r.book_id
           ) THEN 1 ELSE 0 END) AS verified
FROM reviews r
JOIN books b ON b.id = r.book_id
WHERE r.created_at >= '2026-10-01'
GROUP BY b.genre
ORDER BY b.genre
```

| Scenario | median | min | max | runs | rows over fdw | remote executions |
|---|---|---|---|---|---|---|
| MySQL monolith | 931 ms | 925 ms | 959 ms | 5 |  |  |
| PG + fdw | 4408 ms | 4312 ms | 4471 ms | 5 | 1,349,862 | 2 |
| PG + fdw, fetch_size | 3761 ms | 3689 ms | 3819 ms | 5 | 1,349,862 | 2 |
| PG + fdw, remote estimate | timeout (>120 s) |  |  |  |  |  |
| PG native | 981 ms | 976 ms | 1007 ms | 5 |  |  |

<details><summary>Remote queries, <code>pg_fdw</code></summary>

```sql
SELECT `id`, `genre` FROM `bookstore`.`books` ORDER BY `id` IS NULL, `id` ASC
SELECT r1.`customer_id`, r2.`book_id` FROM (`bookstore`.`orders` r1 INNER JOIN `bookstore`.`order_items` r2 ON (((r1.`id` = r2.`order_id`))))
```

</details>

<details><summary>Remote queries, <code>pg_fdw_fetch</code></summary>

```sql
SELECT `id`, `genre` FROM `bookstore`.`books` ORDER BY `id` IS NULL, `id` ASC
SELECT r1.`customer_id`, r2.`book_id` FROM (`bookstore`.`orders` r1 INNER JOIN `bookstore`.`order_items` r2 ON (((r1.`id` = r2.`order_id`))))
```

</details>

<details><summary>Remote queries, <code>pg_fdw_estimate</code></summary>

```sql
SELECT `id`, `genre` FROM `bookstore`.`books` ORDER BY `id` IS NULL, `id` ASC
SELECT `id`, `customer_id` FROM `bookstore`.`orders` ORDER BY `id` IS NULL, `id` ASC
SELECT `order_id`, `book_id` FROM `bookstore`.`order_items` ORDER BY `order_id` IS NULL, `order_id` ASC
```

</details>

Plans: [MySQL monolith](plans/08_verified_reviews.mysql_monolith.txt) · [PG + fdw](plans/08_verified_reviews.pg_fdw.txt) · [PG + fdw, fetch_size](plans/08_verified_reviews.pg_fdw_fetch.txt) · [PG + fdw, remote estimate](plans/08_verified_reviews.pg_fdw_estimate.txt) · [PG native](plans/08_verified_reviews.pg_native.txt)

Previous runs: [runs/](runs/)

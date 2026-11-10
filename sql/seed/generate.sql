-- Mock data for the bookstore. Generated once, in PostgreSQL, into native.*
-- (all 10 tables); `bookstore seed` then copies the 3 migrated tables into
-- app.* and ships everything to MySQL as TSV, so every benchmark scenario
-- queries exactly the same rows.
--
-- Run with: psql -v scale=1 -f generate.sql   (integer scale, 1 = ~3.2M rows)
--
-- Shapes worth knowing when reading query plans:
--   * a few books and customers dominate (skewed ids: low ids are the
--     bestsellers and the loyal customers)
--   * the store grows: there are more orders and reviews every month, and ids
--     follow time, as they would with AUTO_INCREMENT
--   * "today" is 2026-10-31

\set ON_ERROR_STOP on

SELECT
  500 * :scale    AS n_publishers,
  20000 * :scale  AS n_authors,
  100000 * :scale AS n_books,
  100000 * :scale AS n_customers,
  500000 * :scale AS n_orders,
  240000 * :scale AS n_unverified_reviews
\gset

\set countries '{US,US,US,US,US,GB,GB,DE,DE,FR,BR,BR,CA,ES,IT,NL,PT,MX,AU,JP,IN,PL}'
\set first_names '{Olivia,Liam,Emma,Noah,Ava,Oliver,Sophia,Elijah,Isabella,James,Mia,William,Amelia,Benjamin,Harper,Lucas,Evelyn,Henry,Abigail,Theodore,Ana,João,Maria,Pedro,Lucía,Mateo,Chloé,Hugo,Yuki,Haruto,Priya,Arjun,Fatima,Omar,Ingrid,Lars,Zofia,Jakub,Giulia,Marco}'
\set last_names '{Smith,Johnson,Williams,Brown,Jones,Garcia,Miller,Davis,Rodriguez,Martinez,Silva,Santos,Oliveira,Souza,Müller,Schmidt,Schneider,Dubois,Lefebvre,Rossi,Russo,Kowalski,Nowak,Tanaka,Suzuki,Sato,Patel,Sharma,Kim,Lee,Nguyen,Andersson,Johansson,Murphy,Kelly,Fernández,López,Novak,Popescu,Haddad}'

-- Random element of an array
CREATE FUNCTION pg_temp.pick(items text[]) RETURNS text
  LANGUAGE sql VOLATILE
  RETURN items[1 + floor(random() * cardinality(items))::int];

-- Random id in 1..n, skewed towards the small ones. The bigger the exponent,
-- the more the first few ids dominate.
CREATE FUNCTION pg_temp.skewed(n bigint, exponent float8) RETURNS integer
  LANGUAGE sql VOLATILE
  RETURN 1 + floor(n * power(random(), exponent))::int;

-- Timestamp at fraction `frac` (0..1) of the way from lo to hi
CREATE FUNCTION pg_temp.lerp(lo timestamp, hi timestamp, frac float8) RETURNS timestamp
  LANGUAGE sql IMMUTABLE
  RETURN lo + (hi - lo) * frac;

DO $$ BEGIN PERFORM setseed(0.42); END $$;

INSERT INTO native.publishers (id, name, country, founded_year, created_at)
SELECT i,
       pg_temp.pick('{Northwind,Bluebird,Harbor,Lantern,"Red Fern",Summit,Crescent,Atlas,Juniper,"Paper Crane",Ironwood,Saltwater,Tidewater,Granite,Meridian}')
         || ' ' || pg_temp.pick('{Press,Books,Publishing,House,Editions,Media}'),
       pg_temp.pick(:'countries'),
       CASE WHEN random() < 0.9 THEN 1850 + floor(random() * 170)::int END,
       pg_temp.lerp('2008-01-01', '2012-01-01', random())
FROM generate_series(1, :n_publishers) AS i;

INSERT INTO native.authors (id, first_name, last_name, birth_year, country, created_at)
SELECT i,
       pg_temp.pick(:'first_names'),
       pg_temp.pick(:'last_names'),
       CASE WHEN random() < 0.95 THEN 1900 + floor(random() * 100)::int END,
       pg_temp.pick(:'countries'),
       pg_temp.lerp('2010-01-01', '2026-10-31', i::float8 / :n_authors)
FROM generate_series(1, :n_authors) AS i;

INSERT INTO native.books (id, isbn, title, publisher_id, genre, language, published_on, pages, price, created_at)
SELECT i,
       '978' || lpad(i::text, 10, '0'),
       concat_ws(' ',
         pg_temp.pick('{The,A,"Return to the","Beyond the","Songs of the","Notes from the","Tales of the"}'),
         pg_temp.pick('{Silent,Hidden,Last,Broken,Golden,Midnight,Forgotten,Crimson,Secret,Endless,Distant,Burning,Wild,Quiet,Lost,Hollow,Iron,Glass,Winter,Electric}'),
         pg_temp.pick('{River,Kingdom,Garden,Empire,Promise,Machine,Ocean,Library,Station,Orchard,Lighthouse,Shadow,Republic,Harbor,Algorithm,Mountain,Letter,Archive,Frontier,Signal}')),
       pg_temp.skewed(:n_publishers, 2),
       pg_temp.pick('{Fiction,Fiction,Fiction,Fiction,Mystery,Mystery,Mystery,Romance,Romance,Romance,Fantasy,Fantasy,"Science Fiction","Science Fiction",Thriller,Thriller,Biography,History,Self-Help,Business,Children,"Young Adult",Poetry,Cooking,Travel,Science,Philosophy,Comics}'),
       pg_temp.pick('{en,en,en,en,en,en,es,pt,de,fr}'),
       -- most books enter the catalogue close to their publication date
       (created_at - interval '1 day' * floor(7300 * power(random(), 3)))::date,
       80 + floor(random() * 900)::int,
       floor(4 + random() * 46) + 0.99,
       created_at
FROM (
  SELECT i, pg_temp.lerp('2012-01-01', '2026-10-31', i::float8 / :n_books) AS created_at
  FROM generate_series(1, :n_books) AS i
) AS b;

-- 75% of the books have 1 author, 20% have 2, 5% have 3
INSERT INTO native.book_authors (book_id, author_id, author_order)
SELECT b.id, pg_temp.skewed(:n_authors, 1.5), n
FROM native.books AS b
CROSS JOIN LATERAL generate_series(1, CASE WHEN b.id % 20 < 15 THEN 1 WHEN b.id % 20 < 19 THEN 2 ELSE 3 END) AS n
ON CONFLICT DO NOTHING;

INSERT INTO native.customers (id, email, full_name, country, loyalty_tier, created_at)
SELECT i,
       'customer' || i || '@example.com',
       pg_temp.pick(:'first_names') || ' ' || pg_temp.pick(:'last_names'),
       pg_temp.pick(:'countries'),
       pg_temp.pick('{none,none,none,none,none,none,silver,silver,gold,platinum}'),
       -- sign-ups accelerate too: customer i joined at (i/n)^0.7 of the way
       pg_temp.lerp('2015-01-01', '2026-10-31', power(i::float8 / :n_customers, 0.7))
FROM generate_series(1, :n_customers) AS i;

-- Order i is placed at (i/n)^0.6 of the way from 2019 to today, so volume
-- grows over time, by a customer who had already signed up by then.
INSERT INTO native.orders (id, customer_id, status, ordered_at, total_amount, shipping_country)
SELECT o.id,
       o.customer_id,
       CASE
         WHEN o.ordered_at >= '2026-10-29' THEN pg_temp.pick('{pending,paid}')
         WHEN o.ordered_at >= '2026-10-22' THEN pg_temp.pick('{paid,shipped,shipped,delivered}')
         WHEN o.r < 0.03 THEN 'cancelled'
         WHEN o.r < 0.04 THEN 'refunded'
         ELSE 'delivered'
       END,
       o.ordered_at,
       0, -- filled in from order_items below
       c.country
FROM (
  SELECT t.i AS id,
         t.ordered_at,
         random() AS r,
         pg_temp.skewed(
           greatest(1, floor(:n_customers * power(
             extract(epoch FROM t.ordered_at - '2015-01-01')
               / extract(epoch FROM timestamp '2026-10-31' - '2015-01-01'),
             1 / 0.7)))::bigint,
           2) AS customer_id
  FROM (
    SELECT i, pg_temp.lerp('2019-01-01', '2026-10-31 23:59:59', power(i::float8 / :n_orders, 0.6)) AS ordered_at
    FROM generate_series(1, :n_orders) AS i
  ) AS t
) AS o
JOIN native.customers AS c ON c.id = o.customer_id
ORDER BY o.id;

-- 1 to 4 lines per order; bestsellers dominate, quantity is mostly 1
INSERT INTO native.order_items (order_id, line_no, book_id, quantity, unit_price)
SELECT li.order_id, li.line_no, li.book_id, li.quantity, b.price
FROM (
  SELECT o.id AS order_id,
         n AS line_no,
         pg_temp.skewed(:n_books, 3) AS book_id,
         1 + floor(3 * power(random(), 4))::int AS quantity
  FROM native.orders AS o
  CROSS JOIN LATERAL generate_series(1, 1 + (hashint4(o.id) & 3)) AS n
) AS li
JOIN native.books AS b ON b.id = li.book_id
ORDER BY li.order_id, li.line_no;

UPDATE native.orders AS o
SET total_amount = t.total
FROM (
  SELECT order_id, sum(quantity * unit_price) AS total
  FROM native.order_items
  GROUP BY order_id
) AS t
WHERE t.order_id = o.id;

-- The UPDATE left a dead copy of every row behind
VACUUM FULL native.orders;

-- Shipped 12-72h after the order, delivered 1-10 days later: at most 13 days
-- between ordered_at and delivered_at.
INSERT INTO native.shipments (order_id, carrier, tracking_number, status, shipped_at, delivered_at)
SELECT s.order_id,
       s.carrier,
       'TRK' || lpad(s.order_id::text, 12, '0'),
       s.status,
       s.shipped_at,
       CASE WHEN s.status <> 'in_transit' THEN s.shipped_at + interval '1 hour' * floor(24 + random() * 216) END
FROM (
  SELECT o.id AS order_id,
         pg_temp.pick('{UPS,FedEx,DHL,USPS,Correios,"Royal Mail"}') AS carrier,
         CASE o.status WHEN 'shipped' THEN 'in_transit' WHEN 'refunded' THEN 'returned' ELSE 'delivered' END AS status,
         o.ordered_at + interval '1 hour' * floor(12 + random() * 60) AS shipped_at
  FROM native.orders AS o
  WHERE o.status IN ('shipped', 'delivered', 'refunded')
) AS s
ORDER BY s.order_id;

-- ~40% of the reviews come from people who bought the book, the rest from
-- anyone. Every book gets its own rating bias so there are real favourites.
CREATE TEMPORARY TABLE review_source AS
SELECT oi.book_id,
       o.customer_id,
       o.ordered_at + interval '1 hour' * floor(72 + random() * 2000) AS created_at
FROM native.order_items AS oi
JOIN native.orders AS o ON o.id = oi.order_id
WHERE o.status = 'delivered'
  AND (hashint4(oi.id) & 1023) < 138
UNION ALL
SELECT pg_temp.skewed(:n_books, 3),
       pg_temp.skewed(:n_customers, 2),
       pg_temp.lerp('2019-01-01', '2026-10-31', power(random(), 0.6))
FROM generate_series(1, :n_unverified_reviews);

INSERT INTO native.reviews (book_id, customer_id, rating, title, body, helpful_votes, created_at)
SELECT book_id,
       customer_id,
       greatest(1, least(5, round(3.9 + ((hashint4(book_id) & 15) - 7.5) / 6 + (random() - 0.5) * 3)))::int,
       pg_temp.pick('{"Loved it","Could not put it down","Not for me","A masterpiece","Solid read","Disappointing ending","Better than expected",Overrated,"Five stars","Beautifully written","Slow start, great finish","Would recommend"}'),
       substr(
         repeat('Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. ', 4),
         1 + floor(random() * 200)::int,
         40 + floor(random() * 600)::int),
       floor(200 * power(random(), 6))::int,
       created_at
FROM review_source
WHERE created_at < '2026-11-01'
ORDER BY created_at;

-- Each book is stocked in ~60% of the warehouses; ~17% of those rows are
-- below their reorder level.
INSERT INTO native.inventory (book_id, warehouse_code, quantity, reorder_level, updated_at)
SELECT b.id,
       w.code,
       floor(600 * power(random(), 2))::int,
       5 + floor(random() * 26)::int,
       timestamp '2026-10-31' - interval '1 minute' * floor(random() * 129600)
FROM native.books AS b
CROSS JOIN (VALUES (1, 'US-NYC'), (2, 'US-SFO'), (3, 'EU-AMS'), (4, 'BR-SAO')) AS w (n, code)
WHERE (hashint4(b.id * 4 + w.n) & 15) < 10
ORDER BY b.id, w.code;

-- The migrated tables, as the new services own them
INSERT INTO app.reviews SELECT * FROM native.reviews;
INSERT INTO app.inventory SELECT * FROM native.inventory;
INSERT INTO app.shipments SELECT * FROM native.shipments;

-- Explicit ids were inserted everywhere: move the identity sequences past them
DO $$
DECLARE
  col record;
BEGIN
  FOR col IN
    SELECT table_schema, table_name, column_name
    FROM information_schema.columns
    WHERE is_identity = 'YES' AND table_schema IN ('app', 'native')
  LOOP
    EXECUTE format(
      'SELECT setval(pg_get_serial_sequence(%L, %L), coalesce(max(%I), 0) + 1, false) FROM %I.%I',
      col.table_schema || '.' || col.table_name, col.column_name,
      col.column_name, col.table_schema, col.table_name);
  END LOOP;
END $$;

SELECT t.name AS "table", t.home, t.rows
FROM (
            SELECT 1 AS n, 'publishers' AS name, 'MySQL' AS home, count(*) AS rows FROM native.publishers
  UNION ALL SELECT 2,  'authors',      'MySQL',      count(*) FROM native.authors
  UNION ALL SELECT 3,  'books',        'MySQL',      count(*) FROM native.books
  UNION ALL SELECT 4,  'book_authors', 'MySQL',      count(*) FROM native.book_authors
  UNION ALL SELECT 5,  'customers',    'MySQL',      count(*) FROM native.customers
  UNION ALL SELECT 6,  'orders',       'MySQL',      count(*) FROM native.orders
  UNION ALL SELECT 7,  'order_items',  'MySQL',      count(*) FROM native.order_items
  UNION ALL SELECT 8,  'reviews',      'PostgreSQL', count(*) FROM native.reviews
  UNION ALL SELECT 9,  'inventory',    'PostgreSQL', count(*) FROM native.inventory
  UNION ALL SELECT 10, 'shipments',    'PostgreSQL', count(*) FROM native.shipments
) AS t
ORDER BY t.n;

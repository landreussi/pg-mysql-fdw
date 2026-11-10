-- Bestselling authors of Q3 2026: legacy tables only
-- Reporting. A 4-way join + aggregate + ORDER BY + LIMIT that touches no
-- migrated table, so mysql_fdw can ship the whole query to MySQL.
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

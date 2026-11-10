-- Restock report: low-stock NYC inventory (migrated) with title, publisher and recent sales (legacy)
-- Reporting. The selective filter is on the migrated side (~10k of 250k
-- inventory rows); the legacy side only knows "orders since August".
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

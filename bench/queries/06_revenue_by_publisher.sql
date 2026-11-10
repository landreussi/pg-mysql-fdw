-- Revenue per publisher for orders delivered in September 2026: filter only on migrated shipments
-- Reporting, worst case. The only filter is on shipments, so the 4 legacy
-- tables (orders, order_items, books, publishers) get no WHERE clause at all.
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

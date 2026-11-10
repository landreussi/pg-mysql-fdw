-- Same as 06, plus a redundant filter on legacy orders that MySQL can use
-- The fix for 06: orders are delivered at most 13 days after they are placed
-- (see sql/seed/generate.sql), so anything delivered in September was ordered
-- after mid-August. Same result, but now the remote side has a range to scan.
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

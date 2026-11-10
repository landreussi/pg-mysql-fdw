-- Order history page: a customer's latest order lines (legacy) with shipment tracking (migrated)
-- OLTP, driven by the customer's email. The 4 legacy tables are joined
-- remotely; the shipments join and the ORDER BY ... LIMIT happen locally.
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

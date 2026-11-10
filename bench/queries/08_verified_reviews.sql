-- Verified-buyer share of October 2026 reviews per genre: correlated EXISTS from migrated into legacy
-- Reporting. For each of ~7k reviews, check whether the reviewer bought the
-- book: a subquery over orders + order_items parameterized by the review.
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

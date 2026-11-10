-- Book page: one book with its publisher and authors (legacy) plus rating summary and stock (migrated)
-- OLTP. Every table is reached through its primary key or an index on the
-- book id, and the 4-way legacy join carries a constant filter MySQL can use.
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

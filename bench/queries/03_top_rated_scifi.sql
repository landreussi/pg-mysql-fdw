-- Top rated science fiction since 2025: aggregate migrated reviews, then join the legacy catalogue
-- Reporting. The genre filter lets MySQL return only the science fiction
-- slice of books + first author + publisher (~7k rows).
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

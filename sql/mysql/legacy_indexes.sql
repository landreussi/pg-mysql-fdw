-- Secondary indexes and foreign keys for the legacy tables. Same set as the
-- legacy part of sql/pg/indexes.sql.

ALTER TABLE authors
  ADD INDEX authors_name_idx (last_name, first_name);

ALTER TABLE books
  ADD UNIQUE INDEX books_isbn_key (isbn),
  ADD INDEX books_publisher_id_idx (publisher_id),
  ADD INDEX books_genre_published_on_idx (genre, published_on),
  ADD CONSTRAINT books_publisher_id_fkey FOREIGN KEY (publisher_id) REFERENCES publishers (id);

ALTER TABLE book_authors
  ADD INDEX book_authors_author_id_idx (author_id),
  ADD CONSTRAINT book_authors_book_id_fkey FOREIGN KEY (book_id) REFERENCES books (id),
  ADD CONSTRAINT book_authors_author_id_fkey FOREIGN KEY (author_id) REFERENCES authors (id);

ALTER TABLE customers
  ADD UNIQUE INDEX customers_email_key (email),
  ADD INDEX customers_country_idx (country);

ALTER TABLE orders
  ADD INDEX orders_customer_id_ordered_at_idx (customer_id, ordered_at),
  ADD INDEX orders_ordered_at_idx (ordered_at),
  ADD CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers (id);

ALTER TABLE order_items
  ADD UNIQUE INDEX order_items_order_id_line_no_key (order_id, line_no),
  ADD INDEX order_items_book_id_idx (book_id),
  ADD CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders (id),
  ADD CONSTRAINT order_items_book_id_fkey FOREIGN KEY (book_id) REFERENCES books (id);

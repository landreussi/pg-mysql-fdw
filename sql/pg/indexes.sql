-- Secondary indexes and foreign keys, created after the bulk load. Mirrors
-- sql/mysql/legacy_indexes.sql and sql/mysql/migrated_indexes.sql so both
-- engines get the same access paths.

-- app: the migrated tables
CREATE INDEX reviews_book_id_created_at_idx ON app.reviews (book_id, created_at);
CREATE INDEX reviews_customer_id_idx ON app.reviews (customer_id);
CREATE INDEX reviews_created_at_idx ON app.reviews (created_at);

CREATE INDEX inventory_warehouse_code_quantity_idx ON app.inventory (warehouse_code, quantity);

CREATE UNIQUE INDEX shipments_order_id_key ON app.shipments (order_id);
CREATE UNIQUE INDEX shipments_tracking_number_key ON app.shipments (tracking_number);
CREATE INDEX shipments_status_delivered_at_idx ON app.shipments (status, delivered_at);

-- native: the post-migration baseline
CREATE INDEX authors_name_idx ON native.authors (last_name, first_name);

CREATE UNIQUE INDEX books_isbn_key ON native.books (isbn);
CREATE INDEX books_publisher_id_idx ON native.books (publisher_id);
CREATE INDEX books_genre_published_on_idx ON native.books (genre, published_on);

CREATE INDEX book_authors_author_id_idx ON native.book_authors (author_id);

CREATE UNIQUE INDEX customers_email_key ON native.customers (email);
CREATE INDEX customers_country_idx ON native.customers (country);

CREATE INDEX orders_customer_id_ordered_at_idx ON native.orders (customer_id, ordered_at);
CREATE INDEX orders_ordered_at_idx ON native.orders (ordered_at);

CREATE UNIQUE INDEX order_items_order_id_line_no_key ON native.order_items (order_id, line_no);
CREATE INDEX order_items_book_id_idx ON native.order_items (book_id);

CREATE INDEX reviews_book_id_created_at_idx ON native.reviews (book_id, created_at);
CREATE INDEX reviews_customer_id_idx ON native.reviews (customer_id);
CREATE INDEX reviews_created_at_idx ON native.reviews (created_at);

CREATE INDEX inventory_warehouse_code_quantity_idx ON native.inventory (warehouse_code, quantity);

CREATE UNIQUE INDEX shipments_order_id_key ON native.shipments (order_id);
CREATE UNIQUE INDEX shipments_tracking_number_key ON native.shipments (tracking_number);
CREATE INDEX shipments_status_delivered_at_idx ON native.shipments (status, delivered_at);

ALTER TABLE native.books
  ADD FOREIGN KEY (publisher_id) REFERENCES native.publishers (id);
ALTER TABLE native.book_authors
  ADD FOREIGN KEY (book_id) REFERENCES native.books (id),
  ADD FOREIGN KEY (author_id) REFERENCES native.authors (id);
ALTER TABLE native.orders
  ADD FOREIGN KEY (customer_id) REFERENCES native.customers (id);
ALTER TABLE native.order_items
  ADD FOREIGN KEY (order_id) REFERENCES native.orders (id),
  ADD FOREIGN KEY (book_id) REFERENCES native.books (id);
ALTER TABLE native.reviews
  ADD FOREIGN KEY (book_id) REFERENCES native.books (id),
  ADD FOREIGN KEY (customer_id) REFERENCES native.customers (id);
ALTER TABLE native.inventory
  ADD FOREIGN KEY (book_id) REFERENCES native.books (id);
ALTER TABLE native.shipments
  ADD FOREIGN KEY (order_id) REFERENCES native.orders (id);

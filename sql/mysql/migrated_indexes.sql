-- Secondary indexes and foreign keys for the migrated tables in the
-- `monolith` baseline. Same set as the app.* part of sql/pg/indexes.sql, plus
-- the foreign keys that can't exist across the two servers.

ALTER TABLE reviews
  ADD INDEX reviews_book_id_created_at_idx (book_id, created_at),
  ADD INDEX reviews_customer_id_idx (customer_id),
  ADD INDEX reviews_created_at_idx (created_at),
  ADD CONSTRAINT reviews_book_id_fkey FOREIGN KEY (book_id) REFERENCES books (id),
  ADD CONSTRAINT reviews_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers (id);

ALTER TABLE inventory
  ADD INDEX inventory_warehouse_code_quantity_idx (warehouse_code, quantity),
  ADD CONSTRAINT inventory_book_id_fkey FOREIGN KEY (book_id) REFERENCES books (id);

ALTER TABLE shipments
  ADD UNIQUE INDEX shipments_order_id_key (order_id),
  ADD UNIQUE INDEX shipments_tracking_number_key (tracking_number),
  ADD INDEX shipments_status_delivered_at_idx (status, delivered_at),
  ADD CONSTRAINT shipments_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders (id);

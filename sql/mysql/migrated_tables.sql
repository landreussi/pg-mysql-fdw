-- The 3 tables that have already been strangled out to PostgreSQL, as they
-- looked in the monolith before the migration. Only applied to the `monolith`
-- database, which is the all-MySQL baseline; the live `bookstore` database no
-- longer has them.

CREATE TABLE reviews (
  id            BIGINT       NOT NULL AUTO_INCREMENT,
  book_id       INT          NOT NULL,
  customer_id   INT          NOT NULL,
  rating        SMALLINT     NOT NULL,
  title         VARCHAR(200) NOT NULL,
  body          TEXT         NOT NULL,
  helpful_votes INT          NOT NULL DEFAULT 0,
  created_at    DATETIME     NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT reviews_rating_check CHECK (rating BETWEEN 1 AND 5)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE inventory (
  book_id        INT         NOT NULL,
  warehouse_code VARCHAR(10) NOT NULL,
  quantity       INT         NOT NULL,
  reorder_level  INT         NOT NULL,
  updated_at     DATETIME    NOT NULL,
  PRIMARY KEY (book_id, warehouse_code)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE shipments (
  id              BIGINT      NOT NULL AUTO_INCREMENT,
  order_id        INT         NOT NULL,
  carrier         VARCHAR(20) NOT NULL,
  tracking_number VARCHAR(40) NOT NULL,
  status          VARCHAR(20) NOT NULL,
  shipped_at      DATETIME    NOT NULL,
  delivered_at    DATETIME    NULL,
  PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

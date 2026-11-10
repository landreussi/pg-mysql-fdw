-- The 7 tables still owned by the legacy monolith (70% of the schema).
-- Applied to both MySQL databases: `bookstore` (live, read by PostgreSQL via
-- mysql_fdw) and `monolith` (pre-migration baseline).
--
-- Primary keys only: secondary indexes and foreign keys are added after the
-- bulk load, see legacy_indexes.sql. Column order matches sql/pg/schema.sql,
-- the data is shipped over as TSV.

CREATE TABLE publishers (
  id           INT          NOT NULL AUTO_INCREMENT,
  name         VARCHAR(200) NOT NULL,
  country      CHAR(2)      NOT NULL,
  founded_year SMALLINT     NULL,
  created_at   DATETIME     NOT NULL,
  PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE authors (
  id         INT          NOT NULL AUTO_INCREMENT,
  first_name VARCHAR(100) NOT NULL,
  last_name  VARCHAR(100) NOT NULL,
  birth_year SMALLINT     NULL,
  country    CHAR(2)      NOT NULL,
  created_at DATETIME     NOT NULL,
  PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE books (
  id           INT           NOT NULL AUTO_INCREMENT,
  isbn         CHAR(13)      NOT NULL,
  title        VARCHAR(255)  NOT NULL,
  publisher_id INT           NOT NULL,
  genre        VARCHAR(40)   NOT NULL,
  language     CHAR(2)       NOT NULL,
  published_on DATE          NOT NULL,
  pages        SMALLINT      NOT NULL,
  price        DECIMAL(10,2) NOT NULL,
  created_at   DATETIME      NOT NULL,
  PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE book_authors (
  book_id      INT      NOT NULL,
  author_id    INT      NOT NULL,
  author_order SMALLINT NOT NULL,
  PRIMARY KEY (book_id, author_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE customers (
  id           INT          NOT NULL AUTO_INCREMENT,
  email        VARCHAR(255) NOT NULL,
  full_name    VARCHAR(200) NOT NULL,
  country      CHAR(2)      NOT NULL,
  loyalty_tier VARCHAR(10)  NOT NULL,
  created_at   DATETIME     NOT NULL,
  PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE orders (
  id               INT           NOT NULL AUTO_INCREMENT,
  customer_id      INT           NOT NULL,
  status           VARCHAR(20)   NOT NULL,
  ordered_at       DATETIME      NOT NULL,
  total_amount     DECIMAL(12,2) NOT NULL,
  shipping_country CHAR(2)       NOT NULL,
  PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE order_items (
  id         INT           NOT NULL AUTO_INCREMENT,
  order_id   INT           NOT NULL,
  line_no    SMALLINT      NOT NULL,
  book_id    INT           NOT NULL,
  quantity   SMALLINT      NOT NULL,
  unit_price DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

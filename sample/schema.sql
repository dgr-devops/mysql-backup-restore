-- Esquema de la base de ejemplo "tienda" (clientes, pedidos, líneas de pedido).
-- Lo carga scripts/mysql-sample-data.sh y lo usan los tests. Incluye vista, procedimiento,
-- función y trigger para comprobar que la copia con --routines --triggers los conserva.

CREATE TABLE customers (
  id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  name       VARCHAR(80)  NOT NULL,
  email      VARCHAR(120) NOT NULL,
  created_at DATETIME     NOT NULL,
  PRIMARY KEY (id),
  KEY idx_customers_email (email)
) ENGINE=InnoDB;

CREATE TABLE orders (
  id          INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  customer_id INT UNSIGNED  NOT NULL,
  total       DECIMAL(10,2) NOT NULL,
  status      VARCHAR(12)   NOT NULL,
  created_at  DATETIME      NOT NULL,
  notes       VARCHAR(100)  NOT NULL,
  PRIMARY KEY (id),
  KEY idx_orders_customer (customer_id),
  KEY idx_orders_created (created_at),
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id)
) ENGINE=InnoDB;

CREATE TABLE order_items (
  id       INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  order_id INT UNSIGNED  NOT NULL,
  sku      CHAR(12)      NOT NULL,
  qty      SMALLINT      NOT NULL,
  price    DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (id),
  KEY idx_items_order (order_id),
  KEY idx_items_sku (sku),
  CONSTRAINT fk_items_order FOREIGN KEY (order_id) REFERENCES orders (id)
) ENGINE=InnoDB;

CREATE TABLE audit_log (
  id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id   INT UNSIGNED NOT NULL,
  old_status VARCHAR(12)  NOT NULL,
  new_status VARCHAR(12)  NOT NULL,
  changed_at DATETIME     NOT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB;

CREATE VIEW v_customer_totals AS
  SELECT c.id AS customer_id, c.name, COUNT(o.id) AS orders, COALESCE(SUM(o.total), 0) AS spent
  FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
  GROUP BY c.id, c.name;

DELIMITER //

CREATE FUNCTION fn_order_items(p_order INT UNSIGNED) RETURNS INT
  READS SQL DATA
BEGIN
  RETURN (SELECT COUNT(*) FROM order_items WHERE order_id = p_order);
END//

CREATE PROCEDURE sp_customer_orders(IN p_customer INT UNSIGNED)
BEGIN
  SELECT id, total, status, created_at FROM orders WHERE customer_id = p_customer ORDER BY created_at DESC;
END//

CREATE TRIGGER trg_orders_status_audit AFTER UPDATE ON orders
FOR EACH ROW
BEGIN
  IF NEW.status <> OLD.status THEN
    INSERT INTO audit_log (order_id, old_status, new_status, changed_at)
    VALUES (OLD.id, OLD.status, NEW.status, NOW());
  END IF;
END//

DELIMITER ;

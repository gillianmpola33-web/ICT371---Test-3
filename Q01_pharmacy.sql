-- ICT371 Q1: Pharmacy Stock and Daily Sales (PostgreSQL / PL/pgSQL, pg_cron)
-- Run the whole file top to bottom. It is re-runnable.
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS stock_audit, daily_sales, sales, medicines CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE medicines (
  medicine_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_name VARCHAR(100) NOT NULL UNIQUE,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
  sale_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  quantity    INT NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);
CREATE TABLE stock_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INT NOT NULL,
  new_qty     INT NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INT NOT NULL DEFAULT 0,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC AS $$
DECLARE v_price NUMERIC(10,2);
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be a positive number (got %)', p_quantity;
  END IF;
  SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
  END IF;
  RETURN v_price * p_quantity;
END; $$ LANGUAGE plpgsql STABLE;

-- (c) Procedure ------------------------------------------------------------
-- All validation happens before any write, and the procedure runs in one
-- transaction, so an invalid sale leaves sales and medicines unchanged.
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT,
                                           p_sold_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2); v_stock INT;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be a positive number (got %)', p_quantity;
  END IF;
  IF p_sold_on IS NULL THEN RAISE EXCEPTION 'Sale date is required'; END IF;

  SELECT unit_price, stock_qty INTO v_price, v_stock
  FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;   -- lock row
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id; END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: requested %, available %', p_quantity, v_stock;
  END IF;

  INSERT INTO sales(medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);        -- price stored
  UPDATE medicines SET stock_qty = stock_qty - p_quantity        -- deducted once
  WHERE medicine_id = p_medicine_id;
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_medicine_stock_audit() RETURNS trigger AS $$
BEGIN
  INSERT INTO stock_audit(medicine_id, old_qty, new_qty)
  VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)   -- only on real change
EXECUTE FUNCTION trg_medicine_stock_audit();

-- (a) Seed data: medicines, then sales loaded THROUGH the procedure --------
INSERT INTO medicines(medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol 500mg', 2.50, 100),
 ('Amoxicillin 250mg', 8.00, 40),
 ('ORS Sachet',        1.50, 12),
 ('Ibuprofen 200mg',   4.00, 15);

CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(2,  5, CURRENT_DATE - 1);
CALL pr_record_sale(3,  3, CURRENT_DATE - 1);
CALL pr_record_sale(1, 20, CURRENT_DATE);
CALL pr_record_sale(3,  2, CURRENT_DATE);
CALL pr_record_sale(4,  6, CURRENT_DATE);

-- Failure tests (each should raise an error; run one at a time):
-- CALL pr_record_sale(3, 500, CURRENT_DATE);   -- insufficient stock
-- CALL pr_record_sale(99, 1, CURRENT_DATE);    -- unknown medicine
-- CALL pr_record_sale(1, 0, CURRENT_DATE);     -- invalid quantity
-- SELECT fn_sale_value(2, 3);                  -- 24.00

SELECT * FROM stock_audit ORDER BY audit_id;     -- one row per stock change

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

CALL pr_record_sale(2, 32, CURRENT_DATE);        -- Amoxicillin 35 -> 3 (now low)
SELECT * FROM v_low_stock ORDER BY medicine_id;

-- (f) Index ----------------------------------------------------------------
-- Equality column (medicine_id) first, range column (sold_on) second: the
-- B-tree finds one medicine's entries and reads the date range as a
-- contiguous slice instead of scanning every sale.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;
SET enable_seqscan = off;   -- tables are tiny; force the planner to show the index
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
-- UPSERT: the row for the day is replaced, never added to, so reruns are safe.
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_sales(sales_date, total_qty, total_amount)
  SELECT p_day, COALESCE(SUM(quantity),0), COALESCE(SUM(quantity * unit_price),0)
  FROM sales WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END; $$;

SELECT cron.schedule('pharmacy_refresh_sales', '15 0 * * *',
                     $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);         -- rerun: no duplicate / double count
SELECT * FROM daily_sales;
SELECT jobid, jobname, schedule, command FROM cron.job;

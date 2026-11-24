-- ICT371 Q7: Water Meter Readings and Billing (PostgreSQL)
-- Tariff: first 10 units K5 each, units above 10 K8 each.
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE customers (
  customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
  reading_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id      INT NOT NULL REFERENCES customers(customer_id),
  reading_month    DATE NOT NULL,
  previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
  CONSTRAINT ck_reading_month_start CHECK (reading_month = date_trunc('month', reading_month)::date),
  CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
  bill_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
  charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  due_on      DATE NOT NULL,
  CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
  snapshot_date DATE PRIMARY KEY,
  total_due     NUMERIC(14,2) NOT NULL
);

-- (d) Trigger (installed before any data) ----------------------------------
CREATE OR REPLACE FUNCTION trg_reading_check() RETURNS trigger AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
                    NEW.current_reading, NEW.previous_reading;   -- row is not stored
  END IF;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_reading_check();

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC) RETURNS NUMERIC(12,2) AS $$
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN
    RAISE EXCEPTION 'Consumption must be a non-negative number (got %)', p_units;
  END IF;
  RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);
END; $$ LANGUAGE plpgsql IMMUTABLE;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_prev NUMERIC; v_curr NUMERIC; v_charge NUMERIC(12,2);
BEGIN
  IF p_due_on IS NULL THEN RAISE EXCEPTION 'Due date is required'; END IF;
  SELECT previous_reading, current_reading INTO v_prev, v_curr
  FROM readings WHERE reading_id = p_reading_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading_id %', p_reading_id; END IF;
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
  END IF;

  v_charge := fn_water_charge(v_curr - v_prev);      -- derive consumption, call function
  INSERT INTO bills(reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, v_charge, 0, p_due_on);
END; $$;

-- (a) Seed: 3 customers, 6 readings (0, exactly 10, and above 10 units) ------
INSERT INTO customers(full_name) VALUES ('Mutinta Hachamba'), ('Joseph Kapembwa'), ('Lillian Mbewe');
INSERT INTO readings(customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, '2026-09-01', 100, 100),   -- 0 units   -> K0
 (1, '2026-10-01', 100, 110),   -- 10 units  -> K50
 (2, '2026-09-01',  50,  64),   -- 14 units  -> K82
 (2, '2026-10-01',  64,  89),   -- 25 units  -> K170
 (3, '2026-09-01',   0,   7),   -- 7 units   -> K35
 (3, '2026-10-01',   7,  17);   -- 10 units  -> K50

-- Failure tests:
-- INSERT INTO readings(customer_id,reading_month,previous_reading,current_reading)
--   VALUES (3,'2026-11-01',17,10);                -- rejected by trigger, nothing stored
-- UPDATE readings SET current_reading = 1 WHERE reading_id = 6;   -- rejected
-- SELECT fn_water_charge(-1);  SELECT fn_water_charge(NULL);      -- rejected

CALL pr_generate_bill(1, DATE '2026-10-10');
CALL pr_generate_bill(2, DATE '2026-11-10');
CALL pr_generate_bill(3, DATE '2026-10-10');
CALL pr_generate_bill(4, DATE '2026-11-10');
CALL pr_generate_bill(5, DATE '2026-10-10');
CALL pr_generate_bill(6, CURRENT_DATE + 10);
-- CALL pr_generate_bill(6, CURRENT_DATE + 10);   -- already billed
-- CALL pr_generate_bill(99, CURRENT_DATE);       -- unknown reading

UPDATE bills SET amount_paid = 35 WHERE bill_id = 5;   -- fully paid
UPDATE bills SET amount_paid = 40 WHERE bill_id = 3;   -- partly paid
SELECT * FROM bills ORDER BY bill_id;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;
SELECT * FROM v_overdue_bills ORDER BY due_on;

-- (f) Index ----------------------------------------------------------------
-- Partial index on due_on covering only unpaid bills: paid bills (the vast
-- majority over time) are left out, so the index stays small and date-range
-- searches for overdue bills are fast.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;
SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot(snapshot_date, total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0) FROM bills
  ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END; $$;

SELECT cron.schedule('water_refresh_receivables', '30 0 * * *', $$CALL pr_refresh_receivables()$$);
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                      -- rerun replaces today's total
SELECT * FROM receivable_snapshot;
SELECT jobid, jobname, schedule, command FROM cron.job;

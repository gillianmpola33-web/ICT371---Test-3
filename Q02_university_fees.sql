-- ICT371 Q2: University Fee Payments (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
  payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);
CREATE TABLE payment_audit (
  audit_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INT NOT NULL DEFAULT 0,
  total_amount    NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT) RETURNS NUMERIC AS $$
DECLARE v_fee NUMERIC(12,2); v_paid NUMERIC(14,2);
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student_id %', p_student_id; END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
  RETURN v_fee - v_paid;       -- full fee when there are no payments
END; $$ LANGUAGE plpgsql STABLE;

-- (c) Procedure (does NOT write the audit row; the trigger does) ------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC,
                                               p_paid_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be greater than zero (got %)', p_amount;
  END IF;
  IF p_paid_on IS NULL THEN RAISE EXCEPTION 'Payment date is required'; END IF;

  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE; -- serialise payers
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student_id %', p_student_id; END IF;

  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;
  INSERT INTO payments(student_id, amount, paid_on) VALUES (p_student_id, p_amount, p_paid_on);
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_payment_audit() RETURNS trigger AS $$
BEGIN
  INSERT INTO payment_audit(payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit();

-- (a) Seed: 3 students (different balances), 6 payments, student 3 has none -
INSERT INTO students(student_number, full_name, fee_due) VALUES
 ('202400001', 'Mary Tembo',    5000.00),
 ('202400002', 'John Chilufya', 3000.00),
 ('202400003', 'Grace Lungu',   4000.00);

CALL pr_receive_payment(1, 1000, CURRENT_DATE - 5);
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 3);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 4);
CALL pr_receive_payment(2,  800, CURRENT_DATE - 1);
CALL pr_receive_payment(2,  700, CURRENT_DATE);

-- Failure tests:
-- CALL pr_receive_payment(1, NULL, CURRENT_DATE);  -- NULL
-- CALL pr_receive_payment(1, 0,    CURRENT_DATE);  -- zero
-- CALL pr_receive_payment(1, -50,  CURRENT_DATE);  -- negative
-- CALL pr_receive_payment(1, 99999, CURRENT_DATE); -- above balance
-- CALL pr_receive_payment(77, 10,  CURRENT_DATE);  -- unknown student
SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY 1; -- 2000, 500, 4000
SELECT * FROM payment_audit ORDER BY audit_id;       -- 6 rows written by the trigger

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances;
CALL pr_receive_payment(2, 500, CURRENT_DATE);       -- John fully settled
SELECT * FROM v_fee_balances;                        -- John no longer listed

-- (f) Index ----------------------------------------------------------------
-- student_id (equality) then paid_on (range) matches the filter exactly, so one
-- index descent finds a student's payments in date order, with no extra sort.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_collections(collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0) FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;       -- replace, never add
END; $$;

SELECT cron.schedule('fees_refresh_collections', '0 1 * * *',
                     $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);
CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);       -- rerun replaces
SELECT * FROM daily_collections;
SELECT jobid, jobname, schedule, command FROM cron.job;

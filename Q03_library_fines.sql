-- ICT371 Q3: Library Returns and Overdue Fines (PostgreSQL). Fine = K2 per overdue day.
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE books (
  book_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
  loan_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  book_id       INT NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on   DATE NOT NULL,
  due_on        DATE NOT NULL,
  returned_on   DATE NULL,
  fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on),
  CONSTRAINT ck_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);
CREATE TABLE loan_audit (
  audit_id         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  loan_id          INT NOT NULL REFERENCES loans(loan_id),
  old_returned_on  DATE NULL,
  new_returned_on  DATE NULL,
  changed_at       TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INT NOT NULL,
  total_fine    NUMERIC(12,2) NOT NULL
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE) RETURNS NUMERIC AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
  SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan_id %', p_loan_id; END IF;
  v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));   -- returned loans stop accruing
  RETURN 2 * GREATEST(v_end - v_due, 0);               -- on the due date => 0
END; $$ LANGUAGE plpgsql STABLE;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_ret DATE; v_fine NUMERIC;
BEGIN
  SELECT borrowed_on, returned_on INTO v_borrowed, v_ret
  FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan_id %', p_loan_id; END IF;
  IF v_ret IS NOT NULL THEN RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret; END IF;
  IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Return date % is before the borrow date %', p_returned_on, v_borrowed;
  END IF;

  v_fine := fn_loan_fine(p_loan_id, p_returned_on);    -- final fine at return date
  UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine   -- one statement
  WHERE loan_id = p_loan_id;
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_loan_return_audit() RETURNS trigger AS $$
BEGIN
  INSERT INTO loan_audit(loan_id, old_returned_on, new_returned_on)
  VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_return_audit();

-- (a) Seed: 3 books, 6 loans (dates relative to today so they stay overdue) -
INSERT INTO books(title) VALUES
 ('Database System Concepts'), ('Operating System Concepts'), ('Computer Networks');

INSERT INTO loans(book_id, borrower_name, borrowed_on, due_on) VALUES
 (1, 'Mwila Kasonde',    CURRENT_DATE - 20, CURRENT_DATE - 6),   -- open, overdue
 (1, 'Chanda Mutale',    CURRENT_DATE - 3,  CURRENT_DATE + 11),  -- open, on time
 (2, 'Thandiwe Sakala',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- returned late
 (2, 'Bwalya Nkonde',    CURRENT_DATE - 10, CURRENT_DATE - 3),   -- open, overdue
 (3, 'Namukolo Hamoonga',CURRENT_DATE - 15, CURRENT_DATE - 8),   -- returned on due date
 (3, 'Mulenga Chola',    CURRENT_DATE - 2,  CURRENT_DATE + 12);  -- open, on time

CALL pr_return_loan(3, CURRENT_DATE - 10);   -- 6 days late => K12
CALL pr_return_loan(5, CURRENT_DATE - 8);    -- due date => K0

-- Failure tests:
-- CALL pr_return_loan(3, CURRENT_DATE);        -- already returned
-- CALL pr_return_loan(99, CURRENT_DATE);       -- unknown loan
-- CALL pr_return_loan(1, CURRENT_DATE - 40);   -- before borrowed_on
SELECT loan_id, returned_on, fine_amount FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;
UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;      -- unchanged: no audit row
SELECT COUNT(*) AS audit_rows FROM loan_audit;                      -- still 2

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;
SELECT * FROM v_overdue_loans;

-- (f) Index ----------------------------------------------------------------
-- Partial index: only unreturned loans are indexed (a small set), keyed by
-- book_id, so "open loans of this book" is answered without scanning history.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
-- "Overdue" = unreturned as of p_as_of (borrowed by then and not yet returned)
-- and due before p_as_of. Fines are computed as of that date.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO overdue_summary(snapshot_date, overdue_count, total_fine)
  SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
  FROM loans
  WHERE borrowed_on <= p_as_of
    AND (returned_on IS NULL OR returned_on > p_as_of)
    AND due_on < p_as_of
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END; $$;

SELECT cron.schedule('library_refresh_overdue', '10 0 * * *',
                     $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);      -- rerun replaces the same snapshot_date
SELECT * FROM overdue_summary;
SELECT jobid, jobname, schedule, command FROM cron.job;

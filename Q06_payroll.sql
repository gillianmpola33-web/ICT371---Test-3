-- ICT371 Q6: Monthly Payroll Processing (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE employees (
  employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
  payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL,
  gross_pay   NUMERIC(12,2) NOT NULL,
  net_pay     NUMERIC(12,2) NOT NULL,
  CONSTRAINT ck_pay_month_start CHECK (pay_month = date_trunc('month', pay_month)::date),
  CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT) RETURNS NUMERIC AS $$
DECLARE r employees%ROWTYPE; v_net NUMERIC(12,2);
BEGIN
  SELECT * INTO r FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown employee_id %', p_employee_id; END IF;
  v_net := r.basic_salary + r.allowance - r.deduction;
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;
  RETURN v_net;
END; $$ LANGUAGE plpgsql STABLE;

-- (c) Procedure: one transaction, so any failing employee aborts the whole call
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC(12,2);
BEGIN
  IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
    RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
  END IF;

  FOR r IN SELECT employee_id, basic_salary, allowance FROM employees
           WHERE active ORDER BY employee_id
  LOOP
    v_net := fn_net_pay(r.employee_id);            -- raises on invalid calculation
    INSERT INTO payroll(employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
  END LOOP;
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_salary_audit() RETURNS trigger AS $$
BEGIN
  INSERT INTO salary_audit(employee_id, old_salary, new_salary)
  VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit();

-- (a) Seed: active + inactive employees, two payroll months ------------------
INSERT INTO employees(full_name, basic_salary, allowance, deduction, active) VALUES
 ('Alice Banda',   8000, 1500, 500, TRUE),
 ('Brian Phiri',   6000, 1000, 400, TRUE),
 ('Cynthia Mumba', 7000,  800, 300, FALSE),     -- inactive from the start
 ('Daniel Zulu',   5000,  500, 200, TRUE);

CALL pr_process_payroll(DATE '2026-09-01');        -- 3 active employees
UPDATE employees SET active = FALSE WHERE employee_id = 4;   -- Daniel leaves
CALL pr_process_payroll(DATE '2026-10-01');        -- 2 active employees

-- Failure / behaviour tests:
-- CALL pr_process_payroll(DATE '2026-10-15');     -- not a month start
-- SELECT fn_net_pay(99);                          -- unknown employee
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- real change: audited
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- unchanged: no audit row
SELECT * FROM salary_audit;                        -- exactly 1 row
CALL pr_process_payroll(DATE '2026-09-01');        -- rerun: nothing duplicated or altered
SELECT COUNT(*) AS payroll_rows FROM payroll;      -- 3 + 2 = 5
-- Whole-call failure test (negative net): 
-- UPDATE employees SET deduction = 99999 WHERE employee_id = 2;
-- CALL pr_process_payroll(DATE '2026-11-01');     -- raises; no November rows inserted

-- (e) View: LEFT-safe because payroll rows are kept for inactive employees --
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id, e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;
SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;   -- Daniel appears for Sept

-- (f) Index ----------------------------------------------------------------
-- UNIQUE (employee_id, pay_month) leads with employee_id, so it cannot serve a
-- filter on pay_month alone. This index leads with pay_month; it does not
-- duplicate the unique index.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job: 02:00 on day 1, passing the first date of previous month
SELECT cron.schedule('payroll_monthly', '0 2 1 * *',
  $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'payroll_monthly';
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'payroll_monthly')
ORDER BY start_time DESC;

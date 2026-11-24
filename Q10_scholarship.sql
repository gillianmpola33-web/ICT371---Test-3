-- ICT371 Q10: Scholarship Application Assessment (PostgreSQL)
-- Eligible only if age 18-25 inclusive, monthly income <= K3,000, average mark >= 70.
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
  application_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id         INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING',
  CONSTRAINT ck_app_status CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit (
  audit_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status     VARCHAR(10) NOT NULL,
  new_status     VARCHAR(10) NOT NULL,
  changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Age, income and mark are all required';
  END IF;
  IF p_age <= 0 THEN RAISE EXCEPTION 'Age must be positive (got %)', p_age; END IF;
  IF p_income < 0 THEN RAISE EXCEPTION 'Income cannot be negative (got %)', p_income; END IF;
  IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark; END IF;
  RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END; $$ LANGUAGE plpgsql IMMUTABLE;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_decision_audit() RETURNS trigger AS $$
BEGIN
  INSERT INTO decision_audit(application_id, old_status, new_status, changed_at)
  VALUES (OLD.application_id, OLD.status, NEW.status, now());
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit();

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE a applications%ROWTYPE;
BEGIN
  SELECT * INTO a FROM applications WHERE application_id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application % does not exist', p_application_id;
  END IF;
  IF a.status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % has already been assessed (status %)', p_application_id, a.status;
  END IF;

  UPDATE applications
  SET status = CASE WHEN fn_scholarship_eligible(a.age_at_application, a.monthly_income, a.average_mark)
                    THEN 'APPROVED' ELSE 'REJECTED' END
  WHERE application_id = p_application_id;
END; $$;

-- (a) Seed: 6 PENDING applications, qualifying / non-qualifying / boundaries --
INSERT INTO students(student_number, full_name) VALUES
 ('202400021','Natasha Banda'), ('202400022','Kelvin Chisenga'), ('202400023','Mercy Kabwe');

INSERT INTO applications(student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
 (1, 18, 3000.00, 70.00, CURRENT_DATE - 6),   -- all boundaries met        -> APPROVED
 (1, 25, 2999.99, 85.50, CURRENT_DATE - 5),   -- upper age boundary        -> APPROVED
 (2, 17, 1000.00, 90.00, CURRENT_DATE - 4),   -- too young                 -> REJECTED
 (2, 26, 1000.00, 90.00, CURRENT_DATE - 3),   -- too old                   -> REJECTED
 (3, 20, 3000.01, 80.00, CURRENT_DATE - 2),   -- income just above limit   -> REJECTED
 (3, 22, 2000.00, 69.99, CURRENT_DATE - 1);   -- mark just below limit     -> REJECTED

-- Failure tests:
-- SELECT fn_scholarship_eligible(NULL, 100, 80);  SELECT fn_scholarship_eligible(20,-1,80);
-- SELECT fn_scholarship_eligible(0,100,80);       SELECT fn_scholarship_eligible(20,100,101);
-- CALL pr_assess_application(99);                 -- unknown application
CALL pr_assess_application(1);
-- CALL pr_assess_application(1);                  -- already assessed
SELECT application_id, status FROM applications ORDER BY 1;
SELECT * FROM decision_audit;
UPDATE applications SET status = status WHERE application_id = 1;   -- no change: no audit row

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';                        -- income deliberately omitted

-- (f) Index ----------------------------------------------------------------
-- status (equality) first, submitted_on (range) second, matching the search.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
-- Only PENDING rows are selected, so completed applications are never touched
-- and no duplicate audit rows can appear when the job reruns.
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT application_id FROM applications
           WHERE status = 'PENDING' ORDER BY application_id
  LOOP
    CALL pr_assess_application(r.application_id);
  END LOOP;
END; $$;

SELECT cron.schedule('scholarship_assess_pending', '0 8 * * 1', $$CALL pr_assess_pending()$$);
CALL pr_assess_pending();
CALL pr_assess_pending();                           -- rerun: nothing pending, no changes
SELECT application_id, status FROM applications ORDER BY 1;
SELECT COUNT(*) AS audit_rows FROM decision_audit;  -- 6, one per assessed application
SELECT * FROM v_approved_applicants;
SELECT jobid, jobname, schedule, command FROM cron.job;

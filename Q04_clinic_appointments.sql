-- ICT371 Q4: Clinic Appointment Scheduling (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE patients (
  patient_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name  VARCHAR(100) NOT NULL
);
CREATE TABLE doctors (
  doctor_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL
);
CREATE TABLE appointments (
  appointment_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  patient_id      INT NOT NULL REFERENCES patients(patient_id),
  doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time       TIME NOT NULL,
  status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
  CONSTRAINT ck_slot   CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
  CONSTRAINT ck_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);
-- Safety net against race conditions (two sessions passing the trigger check at
-- once): the database itself refuses a second non-cancelled booking of a slot.
CREATE UNIQUE INDEX ux_active_slot ON appointments (doctor_id, appointment_day, slot_time)
WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
  summary_date    DATE PRIMARY KEY,
  booked_count    INT NOT NULL,
  attended_count  INT NOT NULL,
  cancelled_count INT NOT NULL
);

-- (d) Trigger (installed before seed data) ---------------------------------
CREATE OR REPLACE FUNCTION trg_appointment_clash() RETURNS trigger AS $$
BEGIN
  IF NEW.status <> 'CANCELLED' AND EXISTS (
       SELECT 1 FROM appointments a
       WHERE a.doctor_id       = NEW.doctor_id
         AND a.appointment_day = NEW.appointment_day
         AND a.slot_time       = NEW.slot_time
         AND a.status         <> 'CANCELLED'
         AND a.appointment_id IS DISTINCT FROM NEW.appointment_id  -- exclude row being changed
     ) THEN
    RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
                    NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
  END IF;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appointment_clash();

-- (a) Seed: 3 patients, 3 doctors, 6 appointments (no slot clashes) ---------
INSERT INTO patients(full_name) VALUES ('Alice Mwansa'), ('Peter Kunda'), ('Ruth Sinkala');
INSERT INTO doctors(full_name)  VALUES ('Dr. Banda'), ('Dr. Mulenga'), ('Dr. Zimba');

INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status) VALUES
 (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
 (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
 (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
 (1, 2, CURRENT_DATE - 1, '11:00', 'ATTENDED'),
 (2, 3, CURRENT_DATE + 1, '12:00', 'BOOKED'),
 (3, 1, CURRENT_DATE - 1, '09:00', 'CANCELLED');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE) RETURNS INT AS $$
DECLARE v_count INT;
BEGIN
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id; END IF;
  SELECT COUNT(*) INTO v_count FROM appointments
  WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';
  RETURN v_count;                                   -- COUNT gives 0 for an empty day
END; $$ LANGUAGE plpgsql STABLE;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT,
                                                p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient_id %', p_patient_id; END IF;
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id; END IF;
  IF p_day IS NULL OR p_day < CURRENT_DATE THEN
    RAISE EXCEPTION 'Appointment date % is in the past', p_day;
  END IF;
  IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
    RAISE EXCEPTION 'Unsupported slot %. Use 09:00, 10:00, 11:00 or 12:00', p_slot;
  END IF;
  INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');   -- trigger checks clashes
END; $$;

CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, '10:00');       -- OK
-- Failure tests:
-- CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, '10:00');    -- slot clash (trigger)
-- CALL pr_book_appointment(1, 3, CURRENT_DATE - 1, '10:00');    -- past date
-- CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, '13:00');    -- unsupported slot
-- CALL pr_book_appointment(9, 3, CURRENT_DATE + 2, '11:00');    -- unknown patient
-- UPDATE appointments SET slot_time = '10:00' WHERE appointment_id = 1;  -- clash on UPDATE
SELECT fn_daily_load(1, CURRENT_DATE);                           -- 2
SELECT fn_daily_load(3, CURRENT_DATE + 30);                      -- 0

-- (e) View: today's BOOKED only, no unrelated patient data ------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id, p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';
SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) Index ----------------------------------------------------------------
-- Non-unique: one doctor can have many appointments on a day. Leading with
-- appointment_day lets the same index serve "all appointments on a day" too.
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO clinic_summary(summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status = 'BOOKED'),
         COUNT(*) FILTER (WHERE status = 'ATTENDED'),
         COUNT(*) FILTER (WHERE status = 'CANCELLED')
  FROM appointments WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END; $$;

SELECT cron.schedule('clinic_refresh_summary', '0 1 * * *',
                     $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);     -- rerun replaces
SELECT * FROM clinic_summary;
SELECT jobid, jobname, schedule, command FROM cron.job;

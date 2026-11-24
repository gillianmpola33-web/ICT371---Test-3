-- ICT371 Q5: Hostel Room Allocation (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
  room_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
  allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id    INT NOT NULL REFERENCES students(student_id),
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE NULL,
  status        VARCHAR(10) NOT NULL,
  CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
  CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
     OR (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);
-- Safety net for concurrent sessions: one ACTIVE allocation per student.
CREATE UNIQUE INDEX ux_one_active_per_student ON allocations (student_id) WHERE status = 'ACTIVE';

CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT  NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT  NOT NULL,
  free_beds     INT  NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT) RETURNS INT AS $$
DECLARE v_cap INT; v_active INT;
BEGIN
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room_id %', p_room_id; END IF;
  SELECT COUNT(*) INTO v_active FROM allocations
  WHERE room_id = p_room_id AND status = 'ACTIVE';      -- ENDED rows are ignored
  RETURN v_cap - v_active;
END; $$ LANGUAGE plpgsql STABLE;

-- (d) Trigger: enforces rules for direct SQL as well ------------------------
CREATE OR REPLACE FUNCTION trg_allocation_rules() RETURNS trigger AS $$
DECLARE v_cap INT; v_taken INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE; -- serialise per room
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room_id %', NEW.room_id; END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                 AND allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;

    SELECT COUNT(*) INTO v_taken FROM allocations
    WHERE room_id = NEW.room_id AND status = 'ACTIVE'
      AND allocation_id IS DISTINCT FROM NEW.allocation_id;   -- exclude row being updated
    IF v_taken >= v_cap THEN
      RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_cap;
    END IF;
  END IF;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocation_rules();

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student_id %', p_student_id; END IF;
  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room_id %', p_room_id; END IF;
  IF p_allocated_on IS NULL THEN RAISE EXCEPTION 'Allocation date is required'; END IF;

  IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % has no free beds', p_room_id;
  END IF;

  INSERT INTO allocations(student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END; $$;

-- (a) Seed: full, partly occupied and empty rooms ---------------------------
INSERT INTO rooms(room_number, capacity) VALUES ('R101', 2), ('R102', 3), ('R103', 2);
INSERT INTO students(student_number, full_name) VALUES
 ('202400011','Alice Phiri'), ('202400012','Brian Mumba'), ('202400013','Chipo Daka'),
 ('202400014','David Mwale'), ('202400015','Esther Zulu');

CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);   -- R101 full (2/2)
CALL pr_allocate_room(2, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);   -- R102 partly occupied (1/3)
INSERT INTO allocations(student_id, room_id, allocated_on, released_on, status)
VALUES (4, 2, CURRENT_DATE - 90, CURRENT_DATE - 40, 'ENDED');   -- history only
-- R103 empty; student 5 has no allocation

-- Failure tests:
-- CALL pr_allocate_room(5, 1, CURRENT_DATE);   -- room full
-- CALL pr_allocate_room(1, 3, CURRENT_DATE);   -- student already ACTIVE
-- CALL pr_allocate_room(9, 3, CURRENT_DATE);   -- unknown student
-- CALL pr_allocate_room(5, 9, CURRENT_DATE);   -- unknown room
-- INSERT INTO allocations(student_id,room_id,allocated_on,status) VALUES (5,1,CURRENT_DATE,'ACTIVE'); -- trigger: full
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY 1;   -- 0, 2, 2

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)               AS occupied_beds,
       r.capacity - COUNT(a.allocation_id)  AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;
SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) Index ----------------------------------------------------------------
-- Partial index on ACTIVE rows only: occupancy checks and the trigger count only
-- ACTIVE rows by room, and ENDED history (which grows forever) is excluded.
CREATE INDEX idx_alloc_room_active ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot(snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, room_id, occupied_beds, free_beds FROM v_room_occupancy
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;           -- replace on rerun
END; $$;

SELECT cron.schedule('hostel_refresh_occupancy', '55 23 * * *', $$CALL pr_refresh_occupancy()$$);
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                            -- rerun: still one row per room
SELECT * FROM occupancy_snapshot ORDER BY room_id;
SELECT jobid, jobname, schedule, command FROM cron.job;

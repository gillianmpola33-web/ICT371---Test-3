-- ICT371 Q8: Transport Fleet Maintenance (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE vehicles (
  vehicle_id            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  registration          VARCHAR(15) NOT NULL UNIQUE,
  current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
  trip_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on        DATE NOT NULL,
  start_odometer INT NOT NULL CHECK (start_odometer >= 0),
  end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
  vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service INT NOT NULL,
  flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT) RETURNS BOOLEAN AS $$
DECLARE v_km INT;
BEGIN
  SELECT current_odometer - last_service_odometer INTO v_km
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id; END IF;
  RETURN v_km >= 5000;
END; $$ LANGUAGE plpgsql STABLE;

-- (d) Trigger: validates and updates the odometer exactly once per trip ------
CREATE OR REPLACE FUNCTION trg_trip_odometer() RETURNS trigger AS $$
DECLARE v_current INT;
BEGIN
  SELECT current_odometer INTO v_current
  FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;   -- lock the vehicle row
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle_id %', NEW.vehicle_id; END IF;

  IF NEW.start_odometer <> v_current THEN
    RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
                    NEW.start_odometer, v_current;
  END IF;
  IF NEW.end_odometer IS NULL OR NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'End odometer % must be greater than start odometer %',
                    NEW.end_odometer, NEW.start_odometer;
  END IF;

  UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- (c) Procedure: does NOT touch vehicles; the trigger does that --------------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id; END IF;
  IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
    RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
  END IF;
  INSERT INTO trips(vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END; $$;

-- (a) Seed: 3 vehicles with different service positions, 6 trips via procedure
INSERT INTO vehicles(registration, current_odometer, last_service_odometer) VALUES
 ('ABC 1234', 10000,  4000),    -- 6000 km since service  (due)
 ('BAD 5678', 20000, 18000),    -- 2000 km                (not due)
 ('CAE 9012', 30000, 25200);    -- 4800 km                (almost due)

CALL pr_record_trip(1, CURRENT_DATE - 6, 10000, 10200);
CALL pr_record_trip(1, CURRENT_DATE - 3, 10200, 10450);
CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20120);
CALL pr_record_trip(2, CURRENT_DATE - 2, 20120, 20300);
CALL pr_record_trip(3, CURRENT_DATE - 4, 30000, 30150);   -- 4950 km: still below 5000
CALL pr_record_trip(3, CURRENT_DATE - 1, 30150, 30250);   -- 5050 km: now due

-- Failure tests:
-- CALL pr_record_trip(1, CURRENT_DATE, 9999, 10500);     -- start does not match (trigger)
-- CALL pr_record_trip(1, CURRENT_DATE, 10450, 10450);    -- end not greater than start
-- CALL pr_record_trip(9, CURRENT_DATE, 0, 10);           -- unknown vehicle
SELECT vehicle_id, current_odometer, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY 1;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;
SELECT * FROM v_service_due;

-- (f) Index ----------------------------------------------------------------
-- vehicle_id (equality) then trip_on (range): one vehicle's trips for a date
-- range form a contiguous, already sorted slice of the index.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
  -- remove alerts for vehicles that are no longer due (e.g. after servicing)
  DELETE FROM service_alerts a
  WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                    WHERE v.vehicle_id = a.vehicle_id
                      AND v.current_odometer - v.last_service_odometer >= 5000);
  -- insert a new alert, or refresh km on an existing one (one alert per vehicle)
  INSERT INTO service_alerts(vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE SET km_since_service = EXCLUDED.km_since_service;
END; $$;

SELECT cron.schedule('fleet_refresh_service_alerts', '0 6 * * 1', $$CALL pr_refresh_service_alerts()$$);
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                  -- vehicles 1 and 3
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;  -- serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                  -- vehicle 1 alert removed
SELECT jobid, jobname, schedule, command FROM cron.job;

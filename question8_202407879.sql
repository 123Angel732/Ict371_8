--Q8
--a
CREATE TABLE vehicles (
vehicle_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
registration TEXT NOT NULL UNIQUE,
current_odometer NUMERIC(12,2) NOT NULL CHECK (current_odometer >= 0),
last_service_odometer NUMERIC(12,2) NOT NULL
CHECK (last_service_odometer >= 0 AND last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
trip_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
vehicle_id BIGINT NOT NULL REFERENCES vehicles(vehicle_id),
trip_on DATE NOT NULL,
start_odometer NUMERIC(12,2) NOT NULL CHECK (start_odometer >= 0),
end_odometer NUMERIC(12,2) NOT NULL CHECK (end_odometer > start_odometer)
);
CREATE TABLE service_alerts (
vehicle_id BIGINT PRIMARY KEY REFERENCES vehicles(vehicle_id),
km_since_service NUMERIC(12,2) NOT NULL,
flagged_on DATE NOT NULL
);

--b
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id BIGINT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_due BOOLEAN;
BEGIN
SELECT current_odometer - last_service_odometer >= 5000
INTO v_due FROM vehicles WHERE vehicle_id = p_vehicle_id;
IF NOT FOUND THEN
RAISE EXCEPTION 'Unknown vehicle ID %', p_vehicle_id;
END IF;
RETURN v_due;
END; $$;


--c
CREATE OR REPLACE PROCEDURE pr_record_trip(
p_vehicle_id BIGINT, p_trip_on DATE, p_start NUMERIC, p_end NUMERIC)
LANGUAGE plpgsql AS $$
BEGIN
PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
IF NOT FOUND THEN
RAISE EXCEPTION 'Unknown vehicle ID %', p_vehicle_id;
END IF;
IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
RAISE EXCEPTION 'Trip date and valid increasing odometer readings are required';
END IF;
-- The procedure does NOT touch vehicles; the trigger owns that update.
INSERT INTO trips(vehicle_id, trip_on, start_odometer, end_odometer)
VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END; $$;

--d
CREATE OR REPLACE FUNCTION trg_trip_update_odometer()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_current NUMERIC(12,2);
BEGIN
SELECT current_odometer INTO v_current
FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
IF NOT FOUND THEN
RAISE EXCEPTION 'Unknown vehicle';
END IF;
IF NEW.start_odometer <> v_current THEN
RAISE EXCEPTION 'Trip must start at current odometer %, supplied %',
v_current, NEW.start_odometer;
END IF;
IF NEW.end_odometer <= NEW.start_odometer THEN
RAISE EXCEPTION 'End odometer must exceed start odometer';
END IF;
UPDATE vehicles SET current_odometer = NEW.end_odometer -- exactly once per trip
WHERE vehicle_id = NEW.vehicle_id;
RETURN NEW;
END; $$;
CREATE TRIGGER trips_update_vehicle_odometer
BEFORE INSERT ON trips FOR EACH ROW
EXECUTE FUNCTION trg_trip_update_odometer();

--e
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

--f
CREATE INDEX idx_trips_vehicle_trip_on ON trips(vehicle_id, trip_on);
EXPLAIN SELECT trip_id, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
AND trip_on >= DATE '2026-11-01' AND trip_on < DATE '2026-12-01';


--g
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
-- Insert or update one alert for every vehicle that is due.
INSERT INTO service_alerts(vehicle_id, km_since_service, flagged_on)
SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000
ON CONFLICT (vehicle_id) DO UPDATE SET
km_since_service = EXCLUDED.km_since_service,
flagged_on = EXCLUDED.flagged_on;
-- Remove alerts for vehicles that are no longer due (serviced).
DELETE FROM service_alerts a
USING vehicles v
WHERE a.vehicle_id = v.vehicle_id
AND v.current_odometer - v.last_service_odometer < 5000;
END; $$;
-- Schedule: every Monday at 06:00.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('weekly-service-alerts', '0 6 * * 1',
$$CALL pr_refresh_service_alerts()$$);

--seeds
INSERT INTO vehicles(registration, current_odometer, last_service_odometer) VALUES
('ABC100', 12000, 8000), -- 4000 km since service
('DEF200', 25000, 19000), -- 6000 km since service (already due)
('GHI300', 50000, 47000); -- 3000 km since service
-- The trigger is installed before these calls; each trip starts where the last one ended.
CALL pr_record_trip(1, CURRENT_DATE, 12000, 12500);
CALL pr_record_trip(1, CURRENT_DATE, 12500, 13000);
CALL pr_record_trip(2, CURRENT_DATE, 25000, 25500);
CALL pr_record_trip(2, CURRENT_DATE, 25500, 26000);
CALL pr_record_trip(3, CURRENT_DATE, 50000, 50500);
CALL pr_record_trip(3, CURRENT_DATE, 50500, 51000);
SELECT vehicle_id, registration, current_odometer, fn_service_due(vehicle_id) AS due
FROM vehicles ORDER BY vehicle_id; -- ABC100 reaches exactly 5000 km, so it is due
SELECT * FROM v_service_due;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id; -- ABC100 and DEF200
-- Service DEF200: its alert disappears at the next refresh.
UPDATE vehicles SET last_service_odometer = current_odometer WHERE registration = 'DEF200';
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id; 

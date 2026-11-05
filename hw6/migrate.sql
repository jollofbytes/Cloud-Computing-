-- CS528 HW6: copy the HW5 data (database hw5) into the 3NF tables (database hw6).
-- migrate.py runs this once, inside one transaction, only when hw6.requests is empty.
-- Order matters: parents first (countries -> client_ips -> requests -> failed_requests),
-- so every foreign key already has its target row.

-- 1. countries: one row per distinct country name.
--    is_banned is the same on every row of a country; MAX() just picks that value.
INSERT INTO hw6.countries (country_name, is_banned)
SELECT country, MAX(is_banned)
FROM hw5.requests
WHERE country IS NOT NULL
GROUP BY country
ORDER BY country;

-- 2. client_ips: one row per distinct IP, with the id of its country.
--    An IP always comes from one country, so MIN() just picks that one value.
--    (migrate.py first checks that no IP has two countries.)
--    IPs with no X-country header (internet scanners) get country_id = NULL.
INSERT INTO hw6.client_ips (client_ip, country_id)
SELECT r.client_ip, c.country_id
FROM (SELECT client_ip, MIN(country) AS country
      FROM hw5.requests
      WHERE client_ip IS NOT NULL
      GROUP BY client_ip) r
LEFT JOIN hw6.countries c ON c.country_name = r.country;

-- 3. requests: same rows and same request_id values, without country and is_banned.
INSERT INTO hw6.requests (request_id, client_ip, gender, age, income, time_of_day,
                          requested_file, status_code, received_at)
SELECT request_id, client_ip, gender, age, income, time_of_day,
       requested_file, status_code, received_at
FROM hw5.requests
ORDER BY request_id;

-- 4. failed_requests: HW5 stored no request_id here, so match each failure to its request.
--    Both rows were inserted in the same transaction, so for a given file name and
--    error code the 1st failure belongs to the 1st failed request, the 2nd to the 2nd, ...
--    ROW_NUMBER() numbers them in that order on both sides, then we join on the number.
INSERT INTO hw6.failed_requests (failure_id, request_id, request_time)
SELECT f.failure_id, r.request_id, f.request_time
FROM (SELECT failure_id, request_time, requested_file, error_code,
             ROW_NUMBER() OVER (PARTITION BY requested_file, error_code
                                ORDER BY failure_id) AS n
      FROM hw5.failed_requests) f
JOIN (SELECT request_id, requested_file, status_code,
             ROW_NUMBER() OVER (PARTITION BY requested_file, status_code
                                ORDER BY request_id) AS n
      FROM hw5.requests
      WHERE status_code <> 200) r
  ON  r.requested_file = f.requested_file
  AND r.status_code    = f.error_code
  AND r.n              = f.n
ORDER BY f.failure_id;

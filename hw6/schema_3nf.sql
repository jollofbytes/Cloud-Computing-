-- CS528 HW6: the HW5 data in 3rd normal form (MySQL 8.0 on Cloud SQL).
-- The new tables live in a NEW database, hw6, next to the old hw5 database,
-- so the HW5 data is never changed. migrate.py runs this file, then migrate.sql.
--
-- What was wrong with the HW5 table `requests` (not 3NF):
--   request_id -> client_ip -> country      (an IP always comes from the same country)
--   request_id -> country   -> is_banned    (banned depends only on the country)
-- country and is_banned depended on the key only THROUGH another column (a
-- transitive dependency), so they were repeated on every row.
-- Also, `failed_requests` repeated the file name and status of a request.
--
-- Fix: move each fact to the table whose key it depends on.

CREATE DATABASE IF NOT EXISTS hw6;
USE hw6;

-- One row per country. is_banned depends only on the country.
CREATE TABLE IF NOT EXISTS countries (
    country_id    SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    country_name  VARCHAR(64)       NOT NULL,
    is_banned     BOOLEAN           NOT NULL DEFAULT FALSE,
    PRIMARY KEY (country_id),
    UNIQUE KEY uq_country_name (country_name)
);

-- One row per client IP. The country depends only on the IP.
-- country_id is NULL for IPs that sent no X-country header (internet scanners).
CREATE TABLE IF NOT EXISTS client_ips (
    client_ip     VARCHAR(45)       NOT NULL,   -- 45 chars fits IPv6
    country_id    SMALLINT UNSIGNED NULL,
    PRIMARY KEY (client_ip),
    CONSTRAINT fk_ip_country FOREIGN KEY (country_id) REFERENCES countries (country_id)
);

-- One row per request. Every column is a fact about this one request.
CREATE TABLE IF NOT EXISTS requests (
    request_id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    client_ip       VARCHAR(45)     NULL,
    gender          VARCHAR(16)     NULL,       -- X-gender
    age             VARCHAR(16)     NULL,       -- X-age
    income          VARCHAR(16)     NULL,       -- X-income
    time_of_day     DATETIME        NULL,       -- X-time
    requested_file  VARCHAR(512)    NOT NULL,
    status_code     SMALLINT        NOT NULL,   -- what the server answered
    received_at     TIMESTAMP(3)    NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (request_id),
    INDEX idx_status (status_code),
    CONSTRAINT fk_request_ip FOREIGN KEY (client_ip) REFERENCES client_ips (client_ip)
);

-- One row per failed (non-200) request. It points at the request instead of
-- copying its file name and status code (error code = requests.status_code).
CREATE TABLE IF NOT EXISTS failed_requests (
    failure_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    request_id    BIGINT UNSIGNED NOT NULL,
    request_time  DATETIME(3)     NOT NULL,   -- when the server received it (UTC)
    PRIMARY KEY (failure_id),
    UNIQUE KEY uq_failed_request (request_id),
    CONSTRAINT fk_failed_request FOREIGN KEY (request_id) REFERENCES requests (request_id)
);

-- A view (stored query, not stored data) that joins the tables back together.
-- models.py reads from it.
CREATE OR REPLACE VIEW request_details AS
SELECT r.request_id, r.client_ip, c.country_name AS country, c.is_banned,
       r.gender, r.age, r.income, r.time_of_day, r.requested_file,
       r.status_code, r.received_at
FROM requests r
LEFT JOIN client_ips i ON i.client_ip  = r.client_ip
LEFT JOIN countries  c ON c.country_id = i.country_id;

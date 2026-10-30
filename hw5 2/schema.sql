-- CS528 HW5 database schema (MySQL 8.0 on Cloud SQL). setup_schema.py runs this file.

CREATE DATABASE IF NOT EXISTS hw5;
USE hw5;

-- One row per request the web server receives (successful or not).
CREATE TABLE IF NOT EXISTS requests (
    request_id      BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    country         VARCHAR(64)      NULL,       -- X-country
    client_ip       VARCHAR(45)      NULL,       -- X-client-IP (45 chars fits IPv6)
    gender          VARCHAR(16)      NULL,       -- X-gender: Male / Female
    age             VARCHAR(16)      NULL,       -- X-age: 0-16, 17-25, ..., 76+
    income          VARCHAR(16)      NULL,       -- X-income: 0-10k, ..., 250k+
    is_banned       BOOLEAN          NOT NULL DEFAULT FALSE,  -- country on the forbidden list
    time_of_day     DATETIME         NULL,       -- X-time, e.g. 2026-10-27 13:00:00
    requested_file  VARCHAR(512)     NOT NULL,
    status_code     SMALLINT         NOT NULL,   -- what the server answered
    received_at     TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (request_id),
    INDEX idx_country (country),
    INDEX idx_status  (status_code)
);

-- Requests that did not return 200: time, file and error code only.
CREATE TABLE IF NOT EXISTS failed_requests (
    failure_id      BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    request_time    DATETIME(3)      NOT NULL,   -- when the server received it (UTC)
    requested_file  VARCHAR(512)     NOT NULL,
    error_code      SMALLINT         NOT NULL,   -- 400, 404, 501, ...
    PRIMARY KEY (failure_id),
    INDEX idx_error (error_code)
);

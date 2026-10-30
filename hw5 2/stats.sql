-- CS528 HW5 step 7: statistics over the requests table. stats.py runs these.

-- Q1. Successful vs unsuccessful requests
SELECT IF(status_code = 200, 'successful', 'unsuccessful') AS outcome, COUNT(*) AS requests
FROM requests GROUP BY outcome ORDER BY outcome DESC;

-- Q1b. Unsuccessful requests by error code (from the failed_requests table)
SELECT error_code, COUNT(*) AS requests FROM failed_requests GROUP BY error_code ORDER BY error_code;

-- Q2. Requests from banned countries
SELECT COUNT(*) AS banned_country_requests FROM requests WHERE is_banned;

-- Q3. Male vs Female
SELECT gender, COUNT(*) AS requests FROM requests
WHERE gender IS NOT NULL GROUP BY gender ORDER BY requests DESC;

-- Q4. Top 5 countries
SELECT country, COUNT(*) AS requests FROM requests
WHERE country IS NOT NULL GROUP BY country ORDER BY requests DESC, country LIMIT 5;

-- Q5. Age group with the most requests (all groups shown, top one first)
SELECT age, COUNT(*) AS requests FROM requests
WHERE age IS NOT NULL GROUP BY age ORDER BY requests DESC;

-- Q6. Income group with the most requests (all groups shown, top one first)
SELECT income, COUNT(*) AS requests FROM requests
WHERE income IS NOT NULL GROUP BY income ORDER BY requests DESC;

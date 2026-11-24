-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment
-- PostgreSQL. Run the whole file in one go (psql -f, or the pgAdmin Query Tool).

DROP SCHEMA IF EXISTS q10_scholarship CASCADE;
CREATE SCHEMA q10_scholarship;
SET search_path = q10_scholarship, public;

------------------------------------------------------------------
-- (a) Database
------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INT           NOT NULL REFERENCES students(student_id),
    age_at_application INT           NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT         NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

------------------------------------------------------------------
-- (b) Function: fn_scholarship_eligible
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25      -- inclusive
       AND p_income <= 3000
       AND p_mark   >= 70;
END;
$$;

------------------------------------------------------------------
-- (c) Procedure: pr_assess_application
------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql
SET search_path = q10_scholarship, public
AS $$
DECLARE
    v_age    INT;
    v_income NUMERIC;
    v_mark   NUMERIC;
    v_status VARCHAR;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
      INTO v_age, v_income, v_mark, v_status
      FROM applications
     WHERE application_id = p_application_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application: %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status %)', p_application_id, v_status;
    END IF;

    UPDATE applications
       SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                         THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END;
$$;

------------------------------------------------------------------
-- (d) Trigger: record actual status changes
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q10_scholarship, public
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

------------------------------------------------------------------
-- (a, continued) Seed data: six PENDING applications, boundary cases included
------------------------------------------------------------------
INSERT INTO students (student_number, full_name) VALUES
 ('S001', 'Patience Mbewe'),
 ('S002', 'Quincy Lungu'),
 ('S003', 'Rhoda Siame'),
 ('S004', 'Stanley Mutale');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
 (1, 21, 1500.00, 82.00, CURRENT_DATE - 20),   -- clearly qualifies
 (2, 18, 3000.00, 70.00, CURRENT_DATE - 18),   -- lower/upper boundaries: qualifies
 (3, 25, 2000.00, 90.00, CURRENT_DATE - 15),   -- age boundary 25: qualifies
 (4, 26, 1000.00, 85.00, CURRENT_DATE - 12),   -- too old: rejected
 (1, 22, 3000.01, 75.00, CURRENT_DATE - 9),    -- income just over: rejected
 (2, 20, 2500.00, 69.99, CURRENT_DATE - 5);    -- mark just under: rejected

SELECT * FROM applications ORDER BY application_id;

------------------------------------------------------------------
-- (e) View: v_approved_applicants (no household income)
------------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
  FROM applications a
  JOIN students s ON s.student_id = a.student_id
 WHERE a.status = 'APPROVED';

------------------------------------------------------------------
-- (f) Index: status within a submitted_on date range
------------------------------------------------------------------
-- Equality column (status) first, range column (submitted_on) second.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = off;
EXPLAIN
SELECT application_id, student_id, submitted_on
  FROM applications
 WHERE status = 'PENDING'
   AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

------------------------------------------------------------------
-- (g) Scheduled job
------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
SET search_path = q10_scholarship, public
AS $$
DECLARE
    rec RECORD;
BEGIN
    -- Only PENDING rows are selected, so completed applications are never
    -- reassessed and no duplicate audit rows appear on a rerun.
    -- SKIP LOCKED avoids waiting on a row another session is assessing.
    FOR rec IN
        SELECT application_id
          FROM applications
         WHERE status = 'PENDING'
         ORDER BY application_id
           FOR UPDATE SKIP LOCKED
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

-- pg_cron: every Monday at 08:00.
--   CREATE EXTENSION IF NOT EXISTS pg_cron;   (one-off, superuser)
SELECT cron.schedule(
    'scholarship-assess-pending',
    '0 8 * * 1',
    $$CALL q10_scholarship.pr_assess_pending()$$
);
SELECT jobid, jobname, schedule, command FROM cron.job;

------------------------------------------------------------------
-- Tests
------------------------------------------------------------------
-- Run the batch twice: the second run must change nothing
CALL pr_assess_pending();
SELECT COUNT(*) AS audit_rows_after_first_run FROM decision_audit;
CALL pr_assess_pending();
SELECT COUNT(*) AS audit_rows_after_rerun FROM decision_audit;   -- same number

SELECT application_id, age_at_application, monthly_income, average_mark, status
  FROM applications ORDER BY application_id;
SELECT * FROM v_approved_applicants ORDER BY student_number;
SELECT * FROM decision_audit ORDER BY audit_id;

-- Function: boundaries
SELECT fn_scholarship_eligible(18, 3000, 70)    AS lowest_boundary_true,
       fn_scholarship_eligible(25, 3000, 70)    AS age_25_true,
       fn_scholarship_eligible(17, 1000, 90)    AS age_17_false,
       fn_scholarship_eligible(26, 1000, 90)    AS age_26_false,
       fn_scholarship_eligible(20, 3000.01, 90) AS income_over_false,
       fn_scholarship_eligible(20, 1000, 69.99) AS mark_under_false;

DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1, 1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 100, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

-- Procedure: unknown and already assessed applications
DO $$ BEGIN CALL pr_assess_application(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

-- Trigger: an update that does not change the status creates no audit entry
UPDATE applications SET submitted_on = submitted_on WHERE application_id = 1;
SELECT COUNT(*) AS audit_rows_still_same FROM decision_audit;

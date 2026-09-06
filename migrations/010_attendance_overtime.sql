-- ============================================================
-- Migration: Davomatga qo'shimcha ish soati (overtime_hours)
-- Schema: fh
-- 010: attendance.overtime_hours ustuni (faqat qo'lda kiritiladi).
--      hours_worked endi asosiy 8 soat bilan chegaralanadi (obed hisobga
--      olinadi: 08:00-18:00 = 10 soat, ish = 8 soat).
--      monthly_payroll_summary view yangilanadi (total_overtime_hours).
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) attendance.overtime_hours
-- ------------------------------------------------------------
ALTER TABLE fh.attendance
    ADD COLUMN IF NOT EXISTS overtime_hours NUMERIC(5,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN fh.attendance.overtime_hours IS
    'Faqat qolda kiritiladigan qo''shimcha ish soati (asosiy 8 soatdan tashqari, masalan kechki yoki tungi ish). Avtomatik hisoblanmaydi.';

-- ------------------------------------------------------------
-- 2) Oylik hisobot: total_overtime_hours qo'shish
-- ------------------------------------------------------------
DROP VIEW IF EXISTS fh.monthly_payroll_summary;
CREATE VIEW fh.monthly_payroll_summary AS
WITH months AS (
    SELECT DISTINCT employee_id, date_trunc('month', work_date)::date AS month
    FROM fh.attendance
    UNION
    SELECT DISTINCT employee_id, date_trunc('month', work_date)::date AS month
    FROM fh.work_records
    UNION
    SELECT DISTINCT employee_id, date_trunc('month', adjustment_date)::date AS month
    FROM fh.salary_adjustments
),
att_agg AS (
    SELECT employee_id, date_trunc('month', work_date)::date AS month,
           COUNT(*) FILTER (WHERE status = 'present') AS days_present,
           COUNT(*) FILTER (WHERE status = 'absent')  AS days_absent,
           COUNT(*) FILTER (WHERE status = 'late')    AS days_late,
           SUM(hours_worked)                          AS total_hours,
           SUM(COALESCE(overtime_hours, 0))           AS total_overtime_hours
    FROM fh.attendance
    GROUP BY employee_id, date_trunc('month', work_date)
),
work_agg AS (
    SELECT employee_id, date_trunc('month', work_date)::date AS month,
           SUM(computed_amount) AS total_piece_amount
    FROM fh.work_records
    WHERE status = 'approved'
    GROUP BY employee_id, date_trunc('month', work_date)
),
adj_agg AS (
    SELECT employee_id, date_trunc('month', adjustment_date)::date AS month,
           SUM(amount) FILTER (WHERE adjustment_type = 'bonus')   AS total_bonus,
           SUM(amount) FILTER (WHERE adjustment_type = 'penalty') AS total_penalty,
           SUM(amount) FILTER (WHERE adjustment_type = 'advance') AS total_advance
    FROM fh.salary_adjustments
    WHERE status = 'approved'
    GROUP BY employee_id, date_trunc('month', adjustment_date)
)
SELECT
    e.id            AS employee_id,
    e.full_name,
    e.position,
    e.department,
    e.pay_type,
    m.month,
    COALESCE(att.days_present, 0)  AS days_present,
    COALESCE(att.days_absent, 0)   AS days_absent,
    COALESCE(att.days_late, 0)     AS days_late,
    COALESCE(att.total_hours, 0)   AS total_hours,
    COALESCE(att.total_overtime_hours, 0) AS total_overtime_hours,
    CASE WHEN e.pay_type IN ('salary', 'hybrid') THEN COALESCE(e.base_salary, 0) ELSE 0 END AS base_salary_component,
    COALESCE(work.total_piece_amount, 0) AS piece_rate_component,
    COALESCE(adj.total_bonus, 0)    AS total_bonus,
    COALESCE(adj.total_penalty, 0)  AS total_penalty,
    COALESCE(adj.total_advance, 0)  AS total_advance,
    (CASE WHEN e.pay_type IN ('salary', 'hybrid') THEN COALESCE(e.base_salary, 0) ELSE 0 END)
        + COALESCE(work.total_piece_amount, 0)
        + COALESCE(adj.total_bonus, 0)
        - COALESCE(adj.total_penalty, 0)
        - COALESCE(adj.total_advance, 0) AS net_amount
FROM months m
JOIN fh.employees e ON e.id = m.employee_id
LEFT JOIN att_agg  att  ON att.employee_id = m.employee_id AND att.month = m.month
LEFT JOIN work_agg work ON work.employee_id = m.employee_id AND work.month = m.month
LEFT JOIN adj_agg  adj  ON adj.employee_id = m.employee_id AND adj.month = m.month;

COMMENT ON VIEW fh.monthly_payroll_summary IS
    'Oylik yakuniy hisobot: davomat (jami soat + qoshimcha ish soati) + oylik maosh + ishbay summasi + premiya - jarima - avans = net_amount.';

COMMIT;
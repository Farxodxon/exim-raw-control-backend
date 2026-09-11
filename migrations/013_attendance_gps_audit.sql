-- ============================================================
-- Migration: Davomatni kengaytirish — GPS o'z-o'zini belgilash +
-- audit jurnali + erta ketish + ofis joylashuvi
-- Schema: fh
-- 013: attendance GPS ustunlari, attendance_audit_log jadvali,
--      factory_locations jadvali, users.role -> employee, monthly
--      view'ga days_early_leave.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) attendance — GPS + belgilash turi + erta ketish
-- ------------------------------------------------------------
ALTER TABLE fh.attendance
    ADD COLUMN IF NOT EXISTS check_in_lat   DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS check_in_lng   DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS check_out_lat  DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS check_out_lng  DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS marked_by      TEXT NOT NULL DEFAULT 'manager',
    ADD COLUMN IF NOT EXISTS is_early_leave BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE fh.attendance DROP CONSTRAINT IF EXISTS attendance_marked_by_check;
ALTER TABLE fh.attendance ADD CONSTRAINT attendance_marked_by_check
    CHECK (marked_by IN ('self', 'manager'));

-- ------------------------------------------------------------
-- 2) Audit jurnali — har bir tahrirlash uchun bitta qator
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.attendance_audit_log (
    id            SERIAL PRIMARY KEY,
    attendance_id INTEGER NOT NULL REFERENCES fh.attendance(id) ON DELETE CASCADE,
    changed_by    INTEGER REFERENCES fh.users(id),
    changed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    field_name    TEXT NOT NULL,
    old_value     TEXT,
    new_value     TEXT
);

CREATE INDEX IF NOT EXISTS idx_attendance_audit_att ON fh.attendance_audit_log(attendance_id);

-- ------------------------------------------------------------
-- 3) Ofis joylashuvi (GPS radius tekshiruvi uchun)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.factory_locations (
    id            SERIAL PRIMARY KEY,
    name          TEXT NOT NULL,
    latitude      DOUBLE PRECISION NOT NULL,
    longitude     DOUBLE PRECISION NOT NULL,
    radius_meters INTEGER NOT NULL DEFAULT 200,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO fh.factory_locations (name, latitude, longitude, radius_meters)
SELECT 'Asosiy ofis', 41.311081, 69.240562, 200
WHERE NOT EXISTS (SELECT 1 FROM fh.factory_locations);

-- ------------------------------------------------------------
-- 4) users.role CHECK — 'employee' rolini qo'shish
-- ------------------------------------------------------------
DO $$
DECLARE
    constraint_name text;
BEGIN
    SELECT conname INTO constraint_name
    FROM pg_constraint
    WHERE conrelid = 'fh.users'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%role%';

    IF constraint_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE fh.users DROP CONSTRAINT %I', constraint_name);
        EXECUTE 'ALTER TABLE fh.users ADD CONSTRAINT users_role_check CHECK (role IN (
            ''admin'', ''operations_manager'', ''warehouse_controller'',
            ''warehouse_keeper'', ''director'', ''hr_manager'', ''employee''
        ))';
    END IF;
END $$;

-- ------------------------------------------------------------
-- 5) Oylik hisobot view — days_early_leave qo'shish
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
           COUNT(*) FILTER (WHERE is_early_leave)     AS days_early_leave,
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
    COALESCE(att.days_early_leave, 0) AS days_early_leave,
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
    'Oylik yakuniy hisobot: davomat (jami soat + qoshimcha ish soati) + erta ketish + oylik maosh + ishbay summasi + premiya - jarima - avans = net_amount.';

COMMIT;
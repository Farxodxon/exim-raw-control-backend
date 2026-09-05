-- ============================================================
-- Migration: HR bo'limi — xodimlar, davomat, premiya/jarima nazorati
-- Schema: fh
-- NOTE: Single-tenant talqin. Asl 002_hr_module.sql faylidagi
--       `fh.factories` jadvali va `factory_id` ustunlari ushbu loyihada
--       mavjud emas (bir zavod, factory_id yo'q). Shuning uchun
--       `employees` va `salary_adjustments`'dagi factory_id olib
--       tashlandi, `monthly_payroll_summary` VIEW'idan ham chiqarildi.
--       5-bo'lim (users.role CHECK) SAQLANADI — chunki ushbu bazada
--       `users_role_check` constraint mavjud va `hr_manager` qo'shish
--       kerak.
-- Yangi jadvallar yaratiladi (mavjud jadvallarga tegilmaydi),
-- shuning uchun xavfsiz va IDEMPOTENT (IF NOT EXISTS bilan yozilgan).
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Xodimlar jadvali
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.employees (
    id              SERIAL PRIMARY KEY,
    full_name       TEXT NOT NULL,
    position        TEXT,                  -- lavozimi (masalan "Ombor mudiri", "Operator")
    department      TEXT,                  -- bo'lim (masalan "Ishlab chiqarish", "Ombor", "Buxgalteriya")
    phone           TEXT,
    hire_date       DATE NOT NULL DEFAULT CURRENT_DATE,
    termination_date DATE,
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'on_leave', 'terminated')),
    base_salary     NUMERIC(14,2),         -- belgilangan oylik maosh (ixtiyoriy)
    note            TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_employees_status ON fh.employees(status);

-- ------------------------------------------------------------
-- 2) Kunlik davomat jadvali
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.attendance (
    id              SERIAL PRIMARY KEY,
    employee_id     INTEGER NOT NULL REFERENCES fh.employees(id) ON DELETE CASCADE,
    work_date       DATE NOT NULL,
    check_in        TIME,
    check_out       TIME,
    hours_worked    NUMERIC(5,2),          -- backend orqali check_in/check_out'dan hisoblanadi
    status          TEXT NOT NULL DEFAULT 'present'
                    CHECK (status IN (
                        'present',         -- keldi
                        'absent',          -- kelmadi (sababsiz)
                        'late',            -- kech qoldi
                        'sick_leave',      -- kasallik varaqasi
                        'vacation',        -- ta'til
                        'unpaid_leave',    -- ta'tilsiz (haq to'lanmaydigan) ruxsat
                        'business_trip'    -- xizmat safari
                    )),
    note            TEXT,
    recorded_by     INTEGER,               -- fh foydalanuvchi id (kim belgilagan)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (employee_id, work_date)        -- bir kunga bitta yozuv
);

CREATE INDEX IF NOT EXISTS idx_attendance_employee_date ON fh.attendance(employee_id, work_date);
CREATE INDEX IF NOT EXISTS idx_attendance_date ON fh.attendance(work_date);

-- ------------------------------------------------------------
-- 3) Premiya / jarima / avans va boshqa moliyaviy tuzatishlar
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.salary_adjustments (
    id              SERIAL PRIMARY KEY,
    employee_id     INTEGER NOT NULL REFERENCES fh.employees(id) ON DELETE CASCADE,
    adjustment_type TEXT NOT NULL
                    CHECK (adjustment_type IN ('bonus', 'penalty', 'advance', 'other')),
    amount          NUMERIC(14,2) NOT NULL CHECK (amount > 0),  -- har doim musbat, ishorani adjustment_type belgilaydi
    reason          TEXT NOT NULL,          -- sababi (masalan "Rejadan ortiq bajarilgan ish", "Intizom buzilishi")
    adjustment_date DATE NOT NULL DEFAULT CURRENT_DATE,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'approved', 'rejected')),
    approved_by     INTEGER,                -- fh foydalanuvchi id (kim tasdiqlagan)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_salary_adj_employee ON fh.salary_adjustments(employee_id);
CREATE INDEX IF NOT EXISTS idx_salary_adj_date ON fh.salary_adjustments(adjustment_date);
CREATE INDEX IF NOT EXISTS idx_salary_adj_type ON fh.salary_adjustments(adjustment_type);

-- ------------------------------------------------------------
-- 4) Oylik umumiy hisobot uchun VIEW
-- ------------------------------------------------------------
-- Har bir xodim uchun oy kesimida: ishlagan kunlar, kelmagan kunlar,
-- jami premiya, jami jarima, va sof hisoblangan summa (agar base_salary bo'lsa).
-- Izoh: korrelyatsiyalangan subquery GROUP BY bilan mos kelmagani
-- (PG 42803) uchun VIEW oldindan aggregatsiyalangan subquery'lar
-- (JOIN) bilan yozildi — natija bir xil.
CREATE OR REPLACE VIEW fh.monthly_payroll_summary AS
SELECT
    e.id                                            AS employee_id,
    e.full_name,
    e.position,
    e.department,
    e.base_salary,
    am.month,
    am.days_present,
    am.days_absent,
    am.days_late,
    am.days_sick,
    am.days_vacation,
    am.total_hours,
    COALESCE(sa.bonus, 0)                           AS total_bonus,
    COALESCE(sa.penalty, 0)                         AS total_penalty,
    COALESCE(sa.advance, 0)                         AS total_advance
FROM fh.employees e
JOIN (
    SELECT employee_id,
           date_trunc('month', work_date)::date          AS month,
           COUNT(*) FILTER (WHERE status = 'present')     AS days_present,
           COUNT(*) FILTER (WHERE status = 'absent')      AS days_absent,
           COUNT(*) FILTER (WHERE status = 'late')        AS days_late,
           COUNT(*) FILTER (WHERE status = 'sick_leave')  AS days_sick,
           COUNT(*) FILTER (WHERE status = 'vacation')    AS days_vacation,
           COALESCE(SUM(hours_worked), 0)                 AS total_hours
    FROM fh.attendance
    GROUP BY employee_id, date_trunc('month', work_date)::date
) am ON am.employee_id = e.id
LEFT JOIN (
    SELECT employee_id,
           date_trunc('month', adjustment_date)::date     AS month,
           SUM(amount) FILTER (WHERE adjustment_type = 'bonus')    AS bonus,
           SUM(amount) FILTER (WHERE adjustment_type = 'penalty')  AS penalty,
           SUM(amount) FILTER (WHERE adjustment_type = 'advance')  AS advance
    FROM fh.salary_adjustments
    WHERE status = 'approved'
    GROUP BY employee_id, date_trunc('month', adjustment_date)::date
) sa ON sa.employee_id = e.id AND sa.month = am.month;

COMMENT ON VIEW fh.monthly_payroll_summary IS
    'Har bir xodim uchun oylik davomat + premiya/jarima/avans yig''indisi. Frontend hisobot ekrani shu view''dan foydalanadi.';

-- ------------------------------------------------------------
-- 5) users.role CHECK constraintga yangi rol qo'shish
-- ------------------------------------------------------------
-- Ushbu bazada `fh.users.role` uchun CHECK constraint mavjud
-- (`users_role_check`) — uni kengaytirib `hr_manager` qo'shamiz.
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
            ''warehouse_keeper'', ''director'', ''hr_manager''
        ))';
    END IF;
END $$;

COMMIT;

-- ============================================================
-- Tekshirish uchun so'rovlar (qo'lda ishga tushirish uchun)
-- ============================================================
-- SELECT * FROM fh.employees;
-- SELECT * FROM fh.attendance ORDER BY work_date DESC LIMIT 20;
-- SELECT * FROM fh.salary_adjustments ORDER BY adjustment_date DESC LIMIT 20;
-- SELECT * FROM fh.monthly_payroll_summary ORDER BY month DESC;
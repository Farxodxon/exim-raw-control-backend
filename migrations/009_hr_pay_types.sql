-- ============================================================
-- HR: oylik maosh / ishbay (qilgan ishiga qarab) haq turlari
-- Schema: fh
-- Asl manba: 007_hr_pay_types.sql
-- Farqi (joriy sxema uchun moslashgan):
--   1) fh.factories jadvali mavjud EMAS -> piece_rates.factory_id
--      FK'siz, NULL ga ruxsat berilgan holda saqlanadi (kelajakda
--      ko'p zavod qo'llab-quvvatlansa FK qo'shish mumkin). employees
--      da ham factory_id ustuni yo'q, view'ga kiritilmadi.
--   2) avvalgi monthly_payroll_summary view'da days_sick / days_vacation
--      bor edi; yangi view ularni chiqarmaydi — endpoint ham yangilandi.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Xodimning haq turi
-- ------------------------------------------------------------
ALTER TABLE fh.employees
    ADD COLUMN IF NOT EXISTS pay_type TEXT NOT NULL DEFAULT 'salary'
        CHECK (pay_type IN ('salary', 'piece_rate', 'hybrid'));

COMMENT ON COLUMN fh.employees.pay_type IS
    'Xodimga qanday haq to''lanadi: sof oylik, sof ishbay, yoki ikkalasi aralash.';

-- Xodimni tizimdagi login bilan bog'lash (ixtiyoriy) — shu orqali
-- xodim tizimga o'zi kirganda "bu men ishlagan partiya" deb avtomatik
-- aniqlanadi.
ALTER TABLE fh.employees
    ADD COLUMN IF NOT EXISTS user_id INTEGER REFERENCES fh.users(id);

-- ------------------------------------------------------------
-- 2) Ish turlari uchun narx (stavka) jadvali
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.piece_rates (
    id              SERIAL PRIMARY KEY,
    factory_id      INTEGER,                -- fh.factories mavjud emas (yagona zavod), FK shart emas
    work_type       TEXT NOT NULL CHECK (work_type IN ('mixing', 'packaging', 'other')),
    item_id         INTEGER REFERENCES fh.items(id),   -- qaysi mahsulot uchun (NULL = shu work_type uchun umumiy stavka)
    rate_per_unit   NUMERIC(14,4) NOT NULL CHECK (rate_per_unit >= 0),
    unit            TEXT NOT NULL,                      -- masalan "kg", "dona"
    description     TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_piece_rates_lookup
    ON fh.piece_rates (factory_id, work_type, item_id) WHERE is_active = true;

COMMENT ON TABLE fh.piece_rates IS
    'Har bir ish turi/mahsulot uchun 1 birlik ishlab chiqarish/qadoqlash uchun to''lanadigan summa.';

-- ------------------------------------------------------------
-- 3) Bajarilgan ish yozuvlari (ishbay haq hisoblanadigan asos)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.work_records (
    id                   SERIAL PRIMARY KEY,
    employee_id          INTEGER NOT NULL REFERENCES fh.employees(id) ON DELETE CASCADE,
    work_date            DATE NOT NULL DEFAULT CURRENT_DATE,
    work_type            TEXT NOT NULL CHECK (work_type IN ('mixing', 'packaging', 'other')),
    item_id              INTEGER REFERENCES fh.items(id),
    quantity             NUMERIC(14,3) NOT NULL CHECK (quantity > 0),
    unit                 TEXT NOT NULL,
    piece_rate_id        INTEGER REFERENCES fh.piece_rates(id),
    rate_applied         NUMERIC(14,4) NOT NULL,
    computed_amount      NUMERIC(14,2) NOT NULL,
    production_batch_id  INTEGER REFERENCES fh.production_batches(id),
    status               TEXT NOT NULL DEFAULT 'approved'
                          CHECK (status IN ('pending', 'approved', 'rejected')),
    note                 TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_work_records_employee_date ON fh.work_records(employee_id, work_date);
CREATE INDEX IF NOT EXISTS idx_work_records_batch ON fh.work_records(production_batch_id);

COMMENT ON TABLE fh.work_records IS
    'Ishbay/hybrid xodimlar uchun bajargan ishi va shundan hisoblangan summasi. Ishlab chiqarish/qadoqlash partiyasi tugaganda avtomatik yoziladi (agar shu partiyani bajargan xodim belgilangan bo''lsa), yoki qo''lda kiritiladi.';

-- ------------------------------------------------------------
-- 4) Ishlab chiqarish partiyasini xodimga bog'lash
-- ------------------------------------------------------------
ALTER TABLE fh.production_batches
    ADD COLUMN IF NOT EXISTS employee_id INTEGER REFERENCES fh.employees(id);

COMMENT ON COLUMN fh.production_batches.employee_id IS
    'Shu partiyani (aralashtirish yoki qadoqlash) bajargan xodim. Piece_rate/hybrid xodim uchun avtomatik work_records yozuvini yaratish uchun ishlatiladi.';

-- ------------------------------------------------------------
-- 5) Oylik hisobotni yangilash — endi haq turini hisobga oladi
-- ------------------------------------------------------------
-- Avvalgi view'da base_salary ustuni bor; REPLACE yordamida ustun nomini
-- pay_type bo'lib o'zgartirib bo'lmaydi (42P16), shuning uchun DROP + CREATE.
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
           SUM(hours_worked)                          AS total_hours
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
    'Oylik yakuniy hisobot: davomat + oylik maosh (agar bor bo''lsa) + ishbay summasi + premiya - jarima - avans = net_amount.';

COMMIT;
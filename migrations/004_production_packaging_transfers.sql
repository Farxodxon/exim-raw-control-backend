-- ============================================================
-- Migration: Soddalashtirilgan ishlab chiqarish/qadoqlash oqimi +
--            tasdiqlash zanjiri (transfer confirmation) +
--            karantin tekshiruvi + yangi modullar
-- Schema: fh
-- MOSLASHTIRISHLAR:
--   * factory_id mavjud emas (bitta zavod -> factory_settings) —
--     unique index (type) bo'yicha, 'factory_id' umuman ishlatilmaydi
--   * stock_ledger source_type/item_type CHECK kengaytirildi
--   * eski 'production_planning' moduli o'chirildi (is_active=false),
--     yangi 'production'/'packaging'/'planning' kalitlari bilan almashtirildi
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Har bir ombor turi uchun "standart (default) ombor" belgisi
-- ------------------------------------------------------------
ALTER TABLE fh.warehouses
    ADD COLUMN IF NOT EXISTS is_default BOOLEAN NOT NULL DEFAULT false;

-- Har bir tur uchun faqat BITTA default bo'lishi mumkin (bitta zavod)
CREATE UNIQUE INDEX IF NOT EXISTS uq_warehouses_default_per_type
    ON fh.warehouses (type)
    WHERE is_default = true;

-- Asosiy omborlarni default qilib belgilaymiz (nomlar 001-seed ga mos)
UPDATE fh.warehouses SET is_default = true
WHERE type = 'production' AND name = 'Ishlab chiqarish vaqtinchalik ombori';

UPDATE fh.warehouses SET is_default = true
WHERE type = 'semi_finished' AND name = 'Yarim tayyor mahsulotlar ombori';

UPDATE fh.warehouses SET is_default = true
WHERE type = 'packaging' AND name = 'Qadoqlash materiallari ombori';

-- 'finished' turi, 'quarantine', 'defective', 'raw' uchun ATAYLAB
-- default belgilanmaydi — ular qo'lda yoki tur bo'yicha topiladi.

-- ------------------------------------------------------------
-- 2) Bo'limlar orasidagi "tasdiqlash kutilayotgan" o'tkazmalar
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.stock_transfers (
    id                  SERIAL PRIMARY KEY,
    item_id             INTEGER NOT NULL REFERENCES fh.items(id),
    quantity            NUMERIC(14,3) NOT NULL CHECK (quantity > 0),
    unit                TEXT NOT NULL,
    source_warehouse_id INTEGER REFERENCES fh.warehouses(id),  -- NULL: ishlab chiqarish/qadoqlash NATIJASI
    dest_warehouse_id   INTEGER NOT NULL REFERENCES fh.warehouses(id),
    production_batch_id INTEGER REFERENCES fh.production_batches(id),
    status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'confirmed', 'rejected')),
    created_by          INTEGER REFERENCES fh.users(id),
    confirmed_by        INTEGER REFERENCES fh.users(id),
    confirmed_at        TIMESTAMPTZ,
    reject_reason       TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stock_transfers_dest_pending
    ON fh.stock_transfers (dest_warehouse_id)
    WHERE status = 'pending';

COMMENT ON TABLE fh.stock_transfers IS
    'Bo''limlar orasidagi o''tkazmalar. Manba darhol sarflanadi, lekin qabul qiluvchi ombor balansiga faqat status=confirmed bo''lgandan keyin qo''shiladi.';

-- ------------------------------------------------------------
-- 3) Karantin tekshiruvi (kirish nazorati)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.inspections (
    id                  SERIAL PRIMARY KEY,
    item_id             INTEGER NOT NULL REFERENCES fh.items(id),
    quantity            NUMERIC(14,3) NOT NULL CHECK (quantity > 0),
    unit                TEXT NOT NULL,
    quarantine_warehouse_id INTEGER NOT NULL REFERENCES fh.warehouses(id),
    source_ledger_id    INTEGER,
    status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'approved', 'rejected')),
    inspected_by        INTEGER REFERENCES fh.users(id),
    inspected_at        TIMESTAMPTZ,
    note                TEXT,
    resulting_transfer_id INTEGER REFERENCES fh.stock_transfers(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_inspections_pending
    ON fh.inspections (quarantine_warehouse_id)
    WHERE status = 'pending';

COMMENT ON TABLE fh.inspections IS
    'Karantindagi partiyaning sifat tekshiruvi. Qaror bilan fh.stock_transfers orqali Xom-ashyo yoki Brak omboriga yo''naltiriladi.';

-- ------------------------------------------------------------
-- 4) Ishlab chiqarish partiyasiga o'tkazma bilan bog'lanish
-- ------------------------------------------------------------
ALTER TABLE fh.production_batches
    ADD COLUMN IF NOT EXISTS transfer_id INTEGER REFERENCES fh.stock_transfers(id);

COMMENT ON COLUMN fh.production_batches.transfer_id IS
    'Ushbu partiyaning chiqishi (output) qaysi stock_transfers yozuvi orqali qabul qiluvchi omborga yo''naltirilgani.';

-- ------------------------------------------------------------
-- 5) Modullar: yangi kalitlar + eski production_planning'ni o'chirish
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.app_modules (
    module_key   TEXT PRIMARY KEY,
    name_uz      TEXT NOT NULL,
    category     TEXT NOT NULL DEFAULT 'general',
    sort_order   INTEGER NOT NULL DEFAULT 100,
    is_active    BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS fh.user_modules (
    id          SERIAL PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES fh.users(id) ON DELETE CASCADE,
    module_key  TEXT NOT NULL REFERENCES fh.app_modules(module_key) ON DELETE CASCADE,
    granted_by  INTEGER REFERENCES fh.users(id),
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, module_key)
);

INSERT INTO fh.app_modules (module_key, name_uz, category, sort_order) VALUES
    ('production',         'Ishlab chiqarish bo''limi',        'general', 15),
    ('packaging',          'Qadoqlash bo''limi',                'general', 16),
    ('hr',                 'HR bo''limi',                       'general', 10),
    ('planning',           'Rejalar tuzish bo''limi',           'general', 5),
    ('inspection',         'Tekshirish (karantin) bo''limi',    'general', 12),
    ('transfer_confirmations', 'Qabul tasdiqlash bo''limi',    'general', 13)
ON CONFLICT (module_key) DO UPDATE SET name_uz = EXCLUDED.name_uz;

-- Eski nom bilan ishlagan 'production_planning' moduli endi yopiladi —
-- o'rniga 'production' va 'planning' kalitlari ishlatiladi.
UPDATE fh.app_modules SET is_active = false
WHERE module_key = 'production_planning';

-- ------------------------------------------------------------
-- 6) stock_ledger cheklovlarini kengaytirish
-- ------------------------------------------------------------
-- Yangi source_type qiymatlari:
--   production_consume  — aralashtirish/qadoqlashdagi sarf (darhol)
--   reject_reverse      — rad etilgan oddiy transfer manbaga qaytadi
--   reject_to_defective — rad etilgan ishlab chiqarish natijasi Brak omboriga
--   inspection_in       — karantinga qabul yoki qaror bilan kirim
--   inspection_out      — karantindan chiqim (qaror chiqqanda)
ALTER TABLE fh.stock_ledger DROP CONSTRAINT IF EXISTS stock_ledger_source_type_check;
ALTER TABLE fh.stock_ledger ADD CONSTRAINT stock_ledger_source_type_check
CHECK (source_type IN ('manual', 'production_out', 'production_in', 'transfer_out', 'transfer_in',
       'loss', 'write_off', 'production_consume',
       'reject_reverse', 'reject_to_defective', 'inspection_in', 'inspection_out'));

-- item_type'ga fh.items katalogi turlari ham qo'shiladi ('raw','packaging','finished',...)
ALTER TABLE fh.stock_ledger DROP CONSTRAINT IF EXISTS stock_ledger_item_type_check;
ALTER TABLE fh.stock_ledger ADD CONSTRAINT stock_ledger_item_type_check
CHECK (item_type IN ('raw_material', 'product', 'spare_part', 'semi_finished', 'item',
       'raw', 'packaging', 'finished', 'intermediate', 'material'));

COMMIT;

-- ============================================================
-- Tekshirish uchun so'rovlar
-- ============================================================
-- SELECT * FROM fh.warehouses WHERE is_default = true;
-- SELECT * FROM fh.stock_transfers WHERE status = 'pending';
-- SELECT * FROM fh.inspections WHERE status = 'pending';
-- SELECT module_key, name_uz, category, sort_order, is_active FROM fh.app_modules ORDER BY sort_order;
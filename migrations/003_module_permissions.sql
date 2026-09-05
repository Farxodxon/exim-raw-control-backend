-- ============================================================
-- Migration: Bo'lim (modul) darajasidagi ruxsatlar tizimi
-- Schema: fh
-- Maqsad: Admin har bir foydalanuvchiga aynan qaysi bo'lim(lar)
-- (ombor yoki umumiy modul) ko'rinishini belgilay olsin.
-- Foydalanuvchi kirganda FAQAT o'ziga biriktirilgan bo'limlar
-- yon panelda chiqadi, boshqa hech narsa ko'rinmaydi.
--
-- Eslatma: ombor darajasidagi ruxsat uchun ALLAQACHON mavjud bo'lgan
-- fh.user_warehouses jadvali ishlatiladi (warehouse_keeper roli uchun
-- yaratilgan) — uni DUBLIKAT qilmaymiz, faqat kengaytiramiz.
-- Ombor bo'lmagan bo'limlar (HR, hisobotlar va h.k.) uchun YANGI
-- fh.user_modules jadvali qo'shiladi.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Modullar katalogi (ombor bo'lmagan bo'limlar ro'yxati)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.app_modules (
    module_key   TEXT PRIMARY KEY,
    name_uz      TEXT NOT NULL,
    category     TEXT NOT NULL DEFAULT 'general',  -- 'general' | 'admin'
    sort_order   INTEGER NOT NULL DEFAULT 100,
    is_active    BOOLEAN NOT NULL DEFAULT true
);

INSERT INTO fh.app_modules (module_key, name_uz, category, sort_order) VALUES
    ('hr',                 'Xodimlar (HR)',                   'general', 10),
    ('production_planning','Ishlab chiqarish rejalashtirish', 'general', 20),
    ('supplier_orders',    'Yetkazib beruvchi buyurtmalari',  'general', 30),
    ('reports_general',    'Umumiy hisobotlar',               'general', 40),
    ('regime51_report',    '51-rejim hisoboti',               'general', 50),
    ('user_management',    'Foydalanuvchilarni boshqarish',   'admin',   90),
    ('admin_settings',     'Tizim sozlamalari',                'admin',   100)
ON CONFLICT (module_key) DO NOTHING;

-- ------------------------------------------------------------
-- 2) Foydalanuvchi <-> Modul bog'lanishi (ombor bo'lmagan bo'limlar)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.user_modules (
    id          SERIAL PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES fh.users(id) ON DELETE CASCADE,
    module_key  TEXT NOT NULL REFERENCES fh.app_modules(module_key) ON DELETE CASCADE,
    granted_by  INTEGER REFERENCES fh.users(id),
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, module_key)
);

CREATE INDEX IF NOT EXISTS idx_user_modules_user ON fh.user_modules(user_id);

-- ------------------------------------------------------------
-- 3) Ombor ruxsatlari — MAVJUD fh.user_warehouses jadvali ishlatiladi
-- ------------------------------------------------------------
-- Agar u hali yo'q bo'lsa (masalan eski tizimda boshqacha nomlangan),
-- xavfsizlik uchun shu yerda ham yarating:
CREATE TABLE IF NOT EXISTS fh.user_warehouses (
    id            SERIAL PRIMARY KEY,
    user_id       INTEGER NOT NULL REFERENCES fh.users(id) ON DELETE CASCADE,
    warehouse_id  INTEGER NOT NULL REFERENCES fh.warehouses(id) ON DELETE CASCADE,
    granted_by    INTEGER REFERENCES fh.users(id),
    granted_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, warehouse_id)
);

CREATE INDEX IF NOT EXISTS idx_user_warehouses_user ON fh.user_warehouses(user_id);

-- ------------------------------------------------------------
-- 4) Tezkor so'rov uchun umumlashtirilgan VIEW
-- ------------------------------------------------------------
-- Frontend login qilgach shu ikkita manbani birlashtirib chaqiradi.
-- (Backendda ikkita alohida SELECT qilib JSON yig'ish ham mumkin,
-- lekin bitta joyda ko'rish uchun VIEW qulay.)
CREATE OR REPLACE VIEW fh.user_access_overview AS
SELECT
    u.id                AS user_id,
    u.username,
    u.role,
    'warehouse'         AS access_kind,
    w.id::text          AS access_key,
    w.name              AS access_name,
    w.type              AS access_subtype
FROM fh.users u
JOIN fh.user_warehouses uw ON uw.user_id = u.id
JOIN fh.warehouses w ON w.id = uw.warehouse_id
UNION ALL
SELECT
    u.id                AS user_id,
    u.username,
    u.role,
    'module'            AS access_kind,
    m.module_key        AS access_key,
    m.name_uz           AS access_name,
    m.category          AS access_subtype
FROM fh.users u
JOIN fh.user_modules um ON um.user_id = u.id
JOIN fh.app_modules m ON m.module_key = um.module_key;

COMMENT ON VIEW fh.user_access_overview IS
    'Har bir foydalanuvchiga biriktirilgan ombor va modullarning birlashtirilgan ro''yxati. Login javobida frontend sidebar''ini shu asosida quradi.';

COMMIT;

-- ============================================================
-- Tekshirish uchun so'rovlar
-- ============================================================
-- SELECT * FROM fh.app_modules ORDER BY sort_order;
-- SELECT * FROM fh.user_access_overview WHERE user_id = 5;

-- Misol: "Ombor mudiri" (user_id=5) ga xom ashyo va tayyor mahsulot
-- (karobkali) omborlarini biriktirish:
-- INSERT INTO fh.user_warehouses (user_id, warehouse_id, granted_by)
-- SELECT 5, id, 1 FROM fh.warehouses
-- WHERE name IN ('Xom-ashyo ombori', 'Tayyor mahsulotlar (karobkali)')
-- ON CONFLICT DO NOTHING;

-- ============================================================
-- 014: Ish haqi hisoblash v2 (oklad + ishbay) — XOM MA'LUMOT
-- ============================================================
-- Qoidalar: ish-haqi-hisoblash-qoidalari-v1.md
--
-- MUHIM ARXITEKTURA QARORI (prompt talabi):
--   "Hisobot o'qishda hisoblab beriladi (DB'da qayta yozilmaydi —
--    bu shaffoflik va soddalik uchun muhim)."
--
--   Demak DB faqat XOM ma'lumotlarni saqlaydi:
--     • fh.holidays               – rasmiy bayram/dam kunlari
--     • work_records.hours_worked – kun davomida ishlangan soatlar
--     • work_records.day_type     – kun turi (sof_qadoqlash /
--                                   sof_soatbay / aralash)
--
--   Moliyaviy natija (Nigora oklad + Madina ishbay) hisobot
--   o'qilganda Dart kodida hisoblanadi va response'ga qo'shiladi.
--   DB'ga qayta YOZILMAYDI (retroaktiv shaffoflik).
--
--   Nigora (oklad): 5,000,000; 31 kun; 6 dam (5 yakshanba + 1 bayram)
--                   → 25 ish kuni → norma 25×8=200 soat → stavka 25,000
--                   → qo'shimcha 68 soat (6 dam×8=48 + 20 qo'shimcha)
--                   → 1,700,000 → JAMI 6,700,000
--   Madina (ishbay): 7 sof kun (158+142+169+172+141+135+170=1087 dona,
--                   stavka 1500) → 1,630,500 / (7×8=56) = 29,116 o'rtacha
--                   soatlik stavka → aralash kun (2 soat + 95 dona):
--                   95×1500 + 2×29,116 = 200,732
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) BAYRAM/DAM KUNLARI KALENDARI
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fh.holidays (
    id           SERIAL PRIMARY KEY,
    holiday_date DATE NOT NULL UNIQUE,
    label        TEXT NOT NULL DEFAULT 'Bayram',
    created_by   INTEGER REFERENCES fh.users(id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_holidays_month
    ON fh.holidays(holiday_date);

COMMENT ON TABLE fh.holidays IS
    'Rasmiy bayram/dam kunlari. Oklad xodimlarning oylik ish kunlari '
    'sonini (norma soatlari) va qo''shimcha dam-kuni ish haqi stavkasini '
    'hisoblashda ishlatiladi. Yakshanba kunlari avtomatik dam sanaladi, '
    'bu jadvaldagi kunlar qo''shimcha dam kunlardir.';

-- ------------------------------------------------------------
-- 2) WORK_RECORDS: soatlar va kun turi
-- ------------------------------------------------------------
-- hours_worked: kun davomida bajarilgan soatlar.
--   • sof_qadoqlash kunida: odatda 8 soat (kunlik norma)
--   • sof_soatbay kunida:   ishlangan soatlar (masalan 6)
--   • aralash kunida:       qadoqlashdan tashqari bajarilgan soatlar
-- day_type:
--   • sof_qadoqlash – faqat miqdor (dona/kg) x stavka, darhol hisoblanadi
--   • sof_soatbay   – faqat soatbay, o'rtacha soatlik stavka bilan hisoblanadi
--   • aralash       – miqdor x stavka + soatlar x o'rtacha stavka
--   NULL = eski yozuv (faqat miqdor bo'lgan, avtomatik approved)
ALTER TABLE fh.work_records
    ADD COLUMN IF NOT EXISTS hours_worked NUMERIC(5,2),
    ADD COLUMN IF NOT EXISTS day_type TEXT
        CHECK (day_type IN ('sof_qadoqlash', 'sof_soatbay', 'aralash'));

-- 'kutilmoqda' statusi uchun computed_amount NULL bo'lishi kerak:
-- aralash/soatbay kunlar, hali o'rtacha stavka hisoblanmagan (sof kun yo'q)
ALTER TABLE fh.work_records
    ALTER COLUMN computed_amount DROP NOT NULL;

CREATE INDEX IF NOT EXISTS idx_work_records_employee_date
    ON fh.work_records(employee_id, work_date);

COMMENT ON COLUMN fh.work_records.hours_worked IS
    'Kun davomida bajarilgan soatlar (sof_soatbay / aralash kunlari).';
COMMENT ON COLUMN fh.work_records.day_type IS
    'Kun turi: sof_qadoqlash / sof_soatbay / aralash. NULL = eski yozuv '
    '(faqat miqdor, avtomatik approved).';

COMMIT;

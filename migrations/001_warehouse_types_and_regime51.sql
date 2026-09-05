-- ============================================================
-- Migration: Ombor turlarini kengaytirish + 51-rejim hisobi
-- Schema: fh
-- NOTE: Single-tenant talqin. Asl OPENCODE_TASK.md faylidagi SQL
--       `fh.factories` va `warehouses.factory_id`'ga tayangan — ular
--       ushbu loyihada mavjud emas (bir zavod, factory_id yo'q).
--       Shuning uchun 3-bo'lim yagona zavodga moslab qayta yozildi
--       (upsert name bo'yicha).
--       Shuningdek `stock_ledger`'da `item_id` ustuni yo'q (ref_id /
--       ref_barcode ishlatiladi) — indeks shunga moslandi.
-- IDEMPOTENT: bir necha marta ishga tushirsa ham xato bermaydi.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) warehouses.type CHECK constraintni kengaytirish
-- ------------------------------------------------------------
-- type TEXT + CHECK (postgres ENUM emas) — shunday talqin qilinadi.

DO $$
DECLARE
    constraint_name text;
BEGIN
    SELECT conname INTO constraint_name
    FROM pg_constraint
    WHERE conrelid = 'fh.warehouses'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%type%';

    IF constraint_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE fh.warehouses DROP CONSTRAINT %I', constraint_name);
    END IF;
END $$;

ALTER TABLE fh.warehouses
    ADD CONSTRAINT warehouses_type_check
    CHECK (type IN (
        'raw',                -- Xom-ashyo ombori
        'production',         -- Ishlab chiqarish vaqtinchalik/buffer ombori
        'semi_finished',      -- Yarim tayyor mahsulotlar
        'packaging',          -- Qadoqlash materiallari
        'finished',           -- Tayyor mahsulotlar (karobkali va idishlik — bir xil type)
        'purchased_finished', -- Xariddagi tayyor mahsulot
        'purchased_semi',     -- Xariddagi yarim tayyor mahsulot
        'spare_parts',        -- Ehtiyot qismlar
        'sales',              -- Sotuv ombori
        'dealer',             -- Diler/filial ombori
        'quarantine',         -- Karantin/tekshiruv ombori
        'defective',          -- Brak/nikoz ombori
        'returned',           -- Qaytarilgan mahsulotlar ombori
        'retain_sample',      -- Namuna (retain sample) ombori
        'empty_container',    -- Bo'shagan idish/tara ombori
        'other'               -- Aralash ombor (xo'jalik, kantstovar va h.k.)
    ));

-- ------------------------------------------------------------
-- 2) 51-rejim bayrog'i (flag)
-- ------------------------------------------------------------
ALTER TABLE fh.stock_ledger
    ADD COLUMN IF NOT EXISTS is_regime_51 BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN fh.stock_ledger.is_regime_51 IS
    '51-bojxona rejimi ostidagi partiyami? Umumiy balans hisobiga ta''sir qilmaydi, faqat alohida hisobot uchun filtr.';

-- Tezkor filtrlash uchun indeks (item_id yo'q — ref_id/ref_barcode ishlatiladi)
CREATE INDEX IF NOT EXISTS idx_stock_ledger_regime51
    ON fh.stock_ledger (warehouse_id, ref_id, ref_barcode)
    WHERE is_regime_51 = true;

ALTER TABLE fh.supplier_orders
    ADD COLUMN IF NOT EXISTS is_regime_51 BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN fh.supplier_orders.is_regime_51 IS
    'Ushbu buyurtma 51-bojxona rejimi ostida kelganmi (masalan eksport uchun vaqtincha olib kirilgan xom ashyo).';

-- ------------------------------------------------------------
-- 3) Omborlarni yaratish/yangilash (single-tenant — name bo'yicha upsert)
-- ------------------------------------------------------------
DO $$
DECLARE
    wh_defs TEXT[][] := ARRAY[
        ARRAY['Xom-ashyo ombori', 'raw'],
        ARRAY['Qadoqlash materiallari ombori', 'packaging'],
        ARRAY['Yarim tayyor mahsulotlar ombori', 'semi_finished'],
        ARRAY['Sotuv ombori', 'sales'],
        ARRAY['Ishlab chiqarish vaqtinchalik ombori', 'production'],
        ARRAY['Tayyor mahsulotlar (karobkali)', 'finished'],
        ARRAY['Tayyor mahsulotlar (idishlik)', 'finished'],
        ARRAY['Aralash ombor (xo''jalik, kantstovar)', 'other'],
        ARRAY['Ehtiyot qismlar ombori', 'spare_parts'],
        ARRAY['Xariddagi tayyor mahsulot ombori', 'purchased_finished'],
        ARRAY['Xariddagi yarim tayyor mahsulot ombori', 'purchased_semi'],
        ARRAY['Diler/filial ombori', 'dealer'],
        ARRAY['Karantin/tekshiruv ombori', 'quarantine'],
        ARRAY['Brak/nikoz ombori', 'defective'],
        ARRAY['Qaytarilgan mahsulotlar ombori', 'returned'],
        ARRAY['Namuna (retain sample) ombori', 'retain_sample'],
        ARRAY['Bo''shagan idish/tara ombori', 'empty_container']
    ];
    def TEXT[];
BEGIN
    FOREACH def SLICE 1 IN ARRAY wh_defs LOOP
        IF NOT EXISTS (SELECT 1 FROM fh.warehouses WHERE name = def[1]) THEN
            INSERT INTO fh.warehouses (name, type, can_analyze, can_transfer, can_income, can_expense)
            VALUES (def[1], def[2], true, true, true, true);
        ELSE
            UPDATE fh.warehouses
            SET type = def[2]
            WHERE name = def[1];
        END IF;
    END LOOP;
END $$;

COMMIT;

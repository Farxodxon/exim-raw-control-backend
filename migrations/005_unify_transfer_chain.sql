-- ============================================================
-- Migration 005: Butun zanjir "Yubordim (pending) -> Login bilan
-- kirib Qabul qildim (confirm)" mexanizmiga bo'ysunadi.
--
-- Nima o'zgardi (004 ga nisbatan):
--   1) fh.stock_transfers.source_warehouse_id endi NULL bo'lmasligi
--      shart — qo'lda yuborilgan (1,4,5-bo'g'in) o'tkazmalarda ham,
--      avtomatik (2,3-bo'g'in) ishlab chiqarish/qadoqlash chiqishlarida
--      ham to'ldiriladi (faqat "qayerdan kelayotgani" ko'rinishi uchun).
--   2) Zanjir bo'ylab ruxsat etilgan yo'nalishlar (WAREHOUSE TYPE
--      darajasida) fh.warehouse_transfer_routes jadvaliga qo'shildi:
--        raw -> production -> semi_finished -> finished -> sales -> dealer
--   3) Endpoint: POST /transfers/send — qo'lda yuborish (manba DARHOL
--      ayiriladi, qabul qiluvchi tasdiqlaguncha qo'shilmaydi).
-- Schema: fh
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1) Zanjir yo'llari (tip darajasida -> id juftliklariga yoyamiz).
--    Faqat 5 ta qonuniy yo'l: admin qo'shimcha yo'llarni qo'shishi mumkin.
-- ------------------------------------------------------------
INSERT INTO fh.warehouse_transfer_routes (from_warehouse_id, to_warehouse_id)
SELECT s.id, d.id
FROM fh.warehouses s
CROSS JOIN fh.warehouses d
WHERE (s.type, d.type) IN (
    ('raw', 'production'),
    ('production', 'semi_finished'),
    ('semi_finished', 'finished'),
    ('finished', 'sales'),
    ('sales', 'dealer')
)
ON CONFLICT (from_warehouse_id, to_warehouse_id) DO NOTHING;

-- ------------------------------------------------------------
-- 2) fh.stock_transfers.source_warehouse_id doim to'ldiriladi.
--    Avval 004 dagi NULL qatorlarni partiyaning manbasidan qayta
--    to'ldiramiz (022-mixing/packaging chiqishlari).
-- ------------------------------------------------------------
UPDATE fh.stock_transfers st
SET source_warehouse_id = pb.source_warehouse_id
FROM fh.production_batches pb
WHERE st.production_batch_id = pb.id
  AND st.source_warehouse_id IS NULL
  AND pb.source_warehouse_id IS NOT NULL;

ALTER TABLE fh.stock_transfers
    ALTER COLUMN source_warehouse_id SET NOT NULL;

COMMIT;

-- ============================================================
-- Tekshirish uchun so'rovlar
-- ============================================================
-- SELECT * FROM fh.stock_transfers WHERE source_warehouse_id IS NULL;  -- bo'lmasligi kerak
-- SELECT fw.name AS from_wh, fw.type, tw.name AS to_wh, tw.type
-- FROM fh.warehouse_transfer_routes r
-- JOIN fh.warehouses fw ON fw.id = r.from_warehouse_id
-- JOIN fh.warehouses tw ON tw.id = r.to_warehouse_id;
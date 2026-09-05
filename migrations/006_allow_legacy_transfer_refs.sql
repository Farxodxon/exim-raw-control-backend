-- 006_allow_legacy_transfer_refs.sql
-- Legacy katalogdagi mahsulotlar (public.raw_materials / product_warehouses) ham
-- omborlar o'rtasida ko'chirilishi kerak. stock_transfers.item_id endi shartli
-- ravishda fh.items id bo'lishi majburiy emas (stock_ledger ref_id/ref_barcode
-- semantikasi bilan bir xil). FK o'chirildi.
--
--   * stock_transfers.item_id — fh.items FK o'chirildi (legacy ref ham saqlanadi)
ALTER TABLE fh.stock_transfers DROP CONSTRAINT IF EXISTS stock_transfers_item_id_fkey;

COMMIT;
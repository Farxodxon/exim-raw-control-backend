-- 007: Ombordagi mahsulot identifikatorlari kengaytiriladi.
-- Productlar shtrix-kodi (13 xonali) int4 (integer) ga sig'maydi, shuning uchun:
--   - fh.stock_ledger.ref_id          int4 -> int8 (bigint)
--   - fh.stock_transfers.item_id      int4 -> int8 (bigint)
-- (006 da FK olib tashlangan, shuning uchun ustun turi xavfsiz kengayadi.)

ALTER TABLE fh.stock_ledger ALTER COLUMN ref_id TYPE BIGINT;
ALTER TABLE fh.stock_transfers ALTER COLUMN item_id TYPE BIGINT;
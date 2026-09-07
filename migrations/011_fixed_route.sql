-- ============================================================
-- 011_fixed_route.sql
-- Ombor uchun "qat'iy tayinlangan transfer sherigi".
-- Admin har ombor uchun transfer sheriklarini (routes) belgilaydi,
-- xohish bo'lsa bittasini "qat'iy" qilib qo'yishi mumkin — o'shanda
-- foydalanuvchi manzilni TANLAMAYDI, transfer avtomatik shu omborga ketadi.
-- ============================================================

ALTER TABLE fh.warehouses
  ADD COLUMN IF NOT EXISTS fixed_route_to_id INTEGER REFERENCES fh.warehouses(id);

COMMIT;

-- Eslatma: qat'iy sherik ham fh.warehouse_transfer_routes (from→to) da
-- bo'lishi shart — PUT /warehouses/<id> buni ta'minlaydi.
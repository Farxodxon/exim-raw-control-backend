-- ============================================================
-- Tuzatish: modullar ro'yxatini to'g'irlash
-- (asl manba: 006_module_corrections.sql)
-- ============================================================

BEGIN;

-- 1) "Tasdiqlash" alohida modul emas endi — har bir ombor ekranining
--    o'zida "Kutilayotgan qabullar" bo'limi bor. Shu modulni olib
--    tashlaymiz. (fh.user_modules'dagi mos yozuvlar ON DELETE CASCADE
--    orqali avtomatik o'chadi.)
DELETE FROM fh.app_modules WHERE module_key = 'transfer_confirmations';

-- 2) Retseptlarni qo'shish/tahrirlash uchun yangi modul
INSERT INTO fh.app_modules (module_key, name_uz, category, sort_order) VALUES
    ('recipes', 'Retseptlar (BOM) bo''limi', 'general', 8)
ON CONFLICT (module_key) DO UPDATE SET name_uz = EXCLUDED.name_uz;

COMMIT;
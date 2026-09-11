-- 012_dealers.sql — Alohida "Dillerlar" moduli
-- Har bir dillerga 1:1 bog'langan fh.warehouses (type='dealer') ombor yaratiladi.
-- Eski type='dealer' omborlar o'zgarishsiz qoladi (fh.dealers bilan bog'lanmaydi).

CREATE TABLE IF NOT EXISTS fh.dealers (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  market_type VARCHAR(20) NOT NULL CHECK (market_type IN ('domestic', 'export')),
  phone VARCHAR(50),
  address TEXT,
  contact_person VARCHAR(255),
  warehouse_id INTEGER NOT NULL REFERENCES fh.warehouses(id) ON DELETE CASCADE,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP DEFAULT NOW()
);

-- Bitta dillerga bitta ombor (1:1).
CREATE UNIQUE INDEX IF NOT EXISTS dealers_warehouse_uk ON fh.dealers(warehouse_id);
CREATE INDEX IF NOT EXISTS dealers_market_type_idx ON fh.dealers(market_type);
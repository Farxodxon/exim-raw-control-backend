import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';

// 004 migratsiyani bajaradi (migrations/004_production_packaging_transfers.sql).
// Transaktsiya ichida: xatolik bo'lsa hammasi rollback.

Future<Connection> connect() async {
  final env = DotEnv()..load();
  String? url = Platform.environment['DATABASE_URL'];
  if (url == null || url.isEmpty) url = env['DATABASE_URL'];
  final uri = Uri.parse(url!);
  final ui = uri.userInfo.split(':');
  return Connection.open(
    Endpoint(
      host: uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: uri.path.substring(1),
      username: ui.isNotEmpty ? ui[0] : null,
      password: ui.length > 1 ? ui.sublist(1).join(':') : null,
    ),
    settings: ConnectionSettings(sslMode: SslMode.require),
  );
}

Future<void> main() async {
  final c = await connect();
  try {
    await c.execute('BEGIN');

    // 1) is_default
    await c.execute(
        'ALTER TABLE fh.warehouses ADD COLUMN IF NOT EXISTS is_default BOOLEAN NOT NULL DEFAULT false');
    await c.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS uq_warehouses_default_per_type ON fh.warehouses (type) WHERE is_default = true');
    await c.execute(
        "UPDATE fh.warehouses SET is_default = true WHERE type = 'production' AND name = 'Ishlab chiqarish vaqtinchalik ombori'");
    await c.execute(
        "UPDATE fh.warehouses SET is_default = true WHERE type = 'semi_finished' AND name = 'Yarim tayyor mahsulotlar ombori'");
    await c.execute(
        "UPDATE fh.warehouses SET is_default = true WHERE type = 'packaging' AND name = 'Qadoqlash materiallari ombori'");

    // 2) stock_transfers
    await c.execute('''
      CREATE TABLE IF NOT EXISTS fh.stock_transfers (
        id                  SERIAL PRIMARY KEY,
        item_id             INTEGER NOT NULL REFERENCES fh.items(id),
        quantity            NUMERIC(14,3) NOT NULL CHECK (quantity > 0),
        unit                TEXT NOT NULL,
        source_warehouse_id INTEGER REFERENCES fh.warehouses(id),
        dest_warehouse_id   INTEGER NOT NULL REFERENCES fh.warehouses(id),
        production_batch_id INTEGER REFERENCES fh.production_batches(id),
        status              TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'confirmed', 'rejected')),
        created_by          INTEGER REFERENCES fh.users(id),
        confirmed_by        INTEGER REFERENCES fh.users(id),
        confirmed_at        TIMESTAMPTZ,
        reject_reason       TEXT,
        created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
      )''');
    await c.execute(
        'CREATE INDEX IF NOT EXISTS idx_stock_transfers_dest_pending ON fh.stock_transfers (dest_warehouse_id) WHERE status = \'pending\'');

    // 3) inspections
    await c.execute('''
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
      )''');
    await c.execute(
        'CREATE INDEX IF NOT EXISTS idx_inspections_pending ON fh.inspections (quarantine_warehouse_id) WHERE status = \'pending\'');

    // 4) production_batches.transfer_id
    await c.execute(
        'ALTER TABLE fh.production_batches ADD COLUMN IF NOT EXISTS transfer_id INTEGER REFERENCES fh.stock_transfers(id)');

    // 5) app_modules / user_modules + yangi kalitlar + eski modulni yopish
    await c.execute('''
      CREATE TABLE IF NOT EXISTS fh.app_modules (
        module_key   TEXT PRIMARY KEY,
        name_uz      TEXT NOT NULL,
        category     TEXT NOT NULL DEFAULT 'general',
        sort_order   INTEGER NOT NULL DEFAULT 100,
        is_active    BOOLEAN NOT NULL DEFAULT true
      )''');
    await c.execute('''
      CREATE TABLE IF NOT EXISTS fh.user_modules (
        id          SERIAL PRIMARY KEY,
        user_id     INTEGER NOT NULL REFERENCES fh.users(id) ON DELETE CASCADE,
        module_key  TEXT NOT NULL REFERENCES fh.app_modules(module_key) ON DELETE CASCADE,
        granted_by  INTEGER REFERENCES fh.users(id),
        granted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (user_id, module_key)
      )''');
    await c.execute('''
      INSERT INTO fh.app_modules (module_key, name_uz, category, sort_order) VALUES
        ('production', 'Ishlab chiqarish bo''limi', 'general', 15),
        ('packaging', 'Qadoqlash bo''limi', 'general', 16),
        ('hr', 'HR bo''limi', 'general', 10),
        ('planning', 'Rejalar tuzish bo''limi', 'general', 5),
        ('inspection', 'Tekshirish (karantin) bo''limi', 'general', 12),
        ('transfer_confirmations', 'Qabul tasdiqlash bo''limi', 'general', 13)
      ON CONFLICT (module_key) DO UPDATE SET name_uz = EXCLUDED.name_uz''');
    await c.execute(
        "UPDATE fh.app_modules SET is_active = false WHERE module_key = 'production_planning'");

    // 6) stock_ledger CHECK kengaytirish
    await c.execute(
        'ALTER TABLE fh.stock_ledger DROP CONSTRAINT IF EXISTS stock_ledger_source_type_check');
    await c.execute('''
      ALTER TABLE fh.stock_ledger ADD CONSTRAINT stock_ledger_source_type_check
      CHECK (source_type IN ('manual', 'production_out', 'production_in', 'transfer_out', 'transfer_in',
             'loss', 'write_off', 'production_consume',
             'reject_reverse', 'reject_to_defective', 'inspection_in', 'inspection_out'))''');
    await c.execute(
        'ALTER TABLE fh.stock_ledger DROP CONSTRAINT IF EXISTS stock_ledger_item_type_check');
    await c.execute('''
      ALTER TABLE fh.stock_ledger ADD CONSTRAINT stock_ledger_item_type_check
      CHECK (item_type IN ('raw_material', 'product', 'spare_part', 'semi_finished', 'item',
             'raw', 'packaging', 'finished', 'intermediate', 'material'))''');

    await c.execute('COMMIT');
    print('=== 004 migratsiya bajarildi (COMMIT) ===');

    // Verify
    final def = await c.execute(
        'SELECT id, name, type FROM fh.warehouses WHERE is_default = true ORDER BY type');
    print('\n=== Default omborlar ===');
    for (final r in def) {
      print('${r[0]} | ${r[1]} | ${r[2]}');
    }
    final mods = await c.execute(
        'SELECT module_key, name_uz, is_active FROM fh.app_modules ORDER BY sort_order');
    print('\n=== Modullar ===');
    for (final r in mods) {
      print('${r[0]} | ${r[1]} | active=${r[2]}');
    }
    final stCheck = await c.execute('''
      SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'stock_ledger_source_type_check' LIMIT 1''');
    print('\n=== source_type CHECK ===');
    print(stCheck.first[0]);
  } catch (e) {
    try {
      await c.execute('ROLLBACK');
    } catch (_) {}
    print('XATO, ROLLBACK qilindi: $e');
    rethrow;
  } finally {
    await c.close();
  }
}
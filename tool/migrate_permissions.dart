import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';

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

    // 1) Modullar katalogi
    await c.execute('''
      CREATE TABLE IF NOT EXISTS fh.app_modules (
          module_key   TEXT PRIMARY KEY,
          name_uz      TEXT NOT NULL,
          category     TEXT NOT NULL DEFAULT 'general',
          sort_order   INTEGER NOT NULL DEFAULT 100,
          is_active    BOOLEAN NOT NULL DEFAULT true
      )''');

    await c.execute("""
      INSERT INTO fh.app_modules (module_key, name_uz, category, sort_order) VALUES
        ('hr',                 'Xodimlar (HR)',                   'general', 10),
        ('production_planning','Ishlab chiqarish rejalashtirish', 'general', 20),
        ('supplier_orders',    'Yetkazib beruvchi buyurtmalari',  'general', 30),
        ('reports_general',    'Umumiy hisobotlar',               'general', 40),
        ('regime51_report',    '51-rejim hisoboti',               'general', 50),
        ('user_management',    'Foydalanuvchilarni boshqarish',   'admin',   90),
        ('admin_settings',     'Tizim sozlamalari',                'admin',   100)
      ON CONFLICT (module_key) DO NOTHING""");
    print('fh.app_modules + katalog');

    // 2) user_modules
    await c.execute('''
      CREATE TABLE IF NOT EXISTS fh.user_modules (
          id          SERIAL PRIMARY KEY,
          user_id     INTEGER NOT NULL REFERENCES fh.users(id) ON DELETE CASCADE,
          module_key  TEXT NOT NULL REFERENCES fh.app_modules(module_key) ON DELETE CASCADE,
          granted_by  INTEGER REFERENCES fh.users(id),
          granted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
          UNIQUE (user_id, module_key)
      )''');
    await c.execute('CREATE INDEX IF NOT EXISTS idx_user_modules_user ON fh.user_modules(user_id)');
    print('fh.user_modules + index');

    // 3) user_warehouses mavjud bo'lmasa yaratish
    await c.execute('''
      CREATE TABLE IF NOT EXISTS fh.user_warehouses (
          id            SERIAL PRIMARY KEY,
          user_id       INTEGER NOT NULL REFERENCES fh.users(id) ON DELETE CASCADE,
          warehouse_id  INTEGER NOT NULL REFERENCES fh.warehouses(id) ON DELETE CASCADE,
          granted_by    INTEGER REFERENCES fh.users(id),
          granted_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
          UNIQUE (user_id, warehouse_id)
      )''');
    await c.execute('''
      ALTER TABLE fh.user_warehouses
      ADD COLUMN IF NOT EXISTS granted_by INTEGER REFERENCES fh.users(id)''');
    await c.execute('''
      ALTER TABLE fh.user_warehouses
      ADD COLUMN IF NOT EXISTS granted_at TIMESTAMPTZ NOT NULL DEFAULT now()''');
    await c.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_user_warehouses_uniq '
        'ON fh.user_warehouses(user_id, warehouse_id)');
    await c.execute('CREATE INDEX IF NOT EXISTS idx_user_warehouses_user ON fh.user_warehouses(user_id)');
    print('fh.user_warehouses ensured');

    // 4) VIEW
    await c.execute(r'''
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
      JOIN fh.app_modules m ON m.module_key = um.module_key''');
    await c.execute(r'''
      COMMENT ON VIEW fh.user_access_overview IS
        'Har bir foydalanuvchiga biriktirilgan ombor va modullarning birlashtirilgan ro''yxati' ''');
    print('fh.user_access_overview VIEW');

    await c.execute('COMMIT');
    print('\n=== MODUL RUXSATLARI MIGRATSIYASI MUVOFFAQIYATLI ===');
  } catch (e) {
    await c.execute('ROLLBACK');
    print('ROLLBACK: $e');
    rethrow;
  } finally {
    await c.close();
  }
}
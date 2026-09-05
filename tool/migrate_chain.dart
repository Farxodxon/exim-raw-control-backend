import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';

// 005 migratsiyani bajaradi (migrations/005_unify_transfer_chain.sql).
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

    // 1) Zanjir yo'llari (tip darajasida -> id juftliklariga)
    await c.execute('''
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
      ON CONFLICT (from_warehouse_id, to_warehouse_id) DO NOTHING
    ''');

    // 2) NULL manbalarni partiya manbasidan to'ldirish
    await c.execute('''
      UPDATE fh.stock_transfers st
      SET source_warehouse_id = pb.source_warehouse_id
      FROM fh.production_batches pb
      WHERE st.production_batch_id = pb.id
        AND st.source_warehouse_id IS NULL
        AND pb.source_warehouse_id IS NOT NULL
    ''');

    // 3) source_warehouse_id endi doim to'ldiriladi
    await c.execute(
        'ALTER TABLE fh.stock_transfers ALTER COLUMN source_warehouse_id SET NOT NULL');

    await c.execute('COMMIT');
    print('=== 005 migratsiya bajarildi (COMMIT) ===');
  } catch (e) {
    try {
      await c.execute('ROLLBACK');
    } catch (_) {}
    print('XATO, ROLLBACK qilindi: $e');
    rethrow;
  } finally {
    // Verify
    try {
      final nulls = await c.execute(
          'SELECT COUNT(*) FROM fh.stock_transfers WHERE source_warehouse_id IS NULL');
      print('NULL source qatorlar: ${nulls.first[0]}');
      final routes = await c.execute('''
        SELECT fw.name, fw.type, tw.name, tw.type
        FROM fh.warehouse_transfer_routes r
        JOIN fh.warehouses fw ON fw.id = r.from_warehouse_id
        JOIN fh.warehouses tw ON tw.id = r.to_warehouse_id
        ORDER BY fw.type, tw.type
      ''');
      print('\n=== Route lar ===');
      for (final r in routes) {
        print('${r[0]} (${r[1]}) -> ${r[2]} (${r[3]})');
      }
      final col = await c.execute(
          'SELECT is_nullable FROM information_schema.columns WHERE table_schema=\'fh\' AND table_name=\'stock_transfers\' AND column_name=\'source_warehouse_id\'');
      print('\nsource_warehouse_id nullable: ${col.first[0]}');
    } catch (e) {
      print('Verify xato: $e');
    }
    await c.close();
  }
}
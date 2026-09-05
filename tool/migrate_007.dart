import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';

// 007 migratsiyani bajaradi (migrations/007_wide_item_identifiers.sql).
// Product/barcode identifikatorlari int4 ga sig'maydi — ref_id va item_id
// bigint qilinadi, shunda qo'lda transfer (send) shtrix-kodli mahsulotlar
// bilan ham ishlaydi.

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
    await c.execute('ALTER TABLE fh.stock_ledger ALTER COLUMN ref_id TYPE BIGINT');
    await c.execute('ALTER TABLE fh.stock_transfers ALTER COLUMN item_id TYPE BIGINT');
    await c.execute('COMMIT');
    print('=== 007 migratsiya bajarildi (COMMIT) ===');
  } catch (e) {
    try {
      await c.execute('ROLLBACK');
    } catch (_) {}
    print('XATO, ROLLBACK qilindi: $e');
    rethrow;
  } finally {
    final t = await c.execute(
        "SELECT column_name, data_type FROM information_schema.columns "
        "WHERE table_name = 'stock_transfers' AND column_name = 'item_id'");
    print('stock_transfers.item_id holati: ${t.isNotEmpty ? '${t.first[0]} ${t.first[1]}' : 'topilmadi'}');
    final l = await c.execute(
        "SELECT column_name, data_type FROM information_schema.columns "
        "WHERE table_name = 'stock_ledger' AND column_name = 'ref_id'");
    print('stock_ledger.ref_id holati: ${l.isNotEmpty ? '${l.first[0]} ${l.first[1]}' : 'topilmadi'}');
    await c.close();
  }
}
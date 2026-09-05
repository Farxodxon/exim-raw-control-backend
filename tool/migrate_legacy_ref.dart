import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';

// 006 migratsiyani bajaradi (migrations/006_allow_legacy_transfer_refs.sql).
// stock_transfers.item_id FK (fh.items) o'chiriladi — legacy ref ham ko'chishi mumkin.

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
    await c.execute(
        'ALTER TABLE fh.stock_transfers DROP CONSTRAINT IF EXISTS stock_transfers_item_id_fkey');
    await c.execute('COMMIT');
    print('=== 006 migratsiya bajarildi (COMMIT) ===');
  } catch (e) {
    try {
      await c.execute('ROLLBACK');
    } catch (_) {}
    print('XATO, ROLLBACK qilindi: $e');
    rethrow;
  } finally {
    final cols = await c.execute(
        "SELECT conname FROM pg_constraint WHERE conname = 'stock_transfers_item_id_fkey'");
    print('FK qolgani: ${cols.length > 0}');
    await c.close();
  }
}
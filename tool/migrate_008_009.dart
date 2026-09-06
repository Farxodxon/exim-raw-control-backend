import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';

// 008+009 migratsiyalarni bajaradi:
//   008_module_corrections.sql - modullar ro'yxati tuzatmasi
//   009_hr_pay_types.sql       - HR pay_type / piece_rates / work_records
// PostgreSQL driver bir chaqiruvda bitta statement qo'llaydi, shuning
// uchun fayl comment-satrlardan tozalanib ';' bo'yicha bo'linadi va
// bitta transaktsiyada bajariladi. Pgbouncer keshini DISCARD ALL tozalaydi.

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

// Comment satrlarini o'chiradi va ';' bo'yicha alohida statementlarga bo'ladi.
List<String> splitStatements(String sql) {
  final clean = sql
      .split('\n')
      .where((l) => !l.trim().startsWith('--'))
      .join('\n');
  final parts = clean.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty);
  return parts.toList();
}

Future<void> main() async {
  final c = await connect();
  try {
    await c.execute('DISCARD ALL');
    for (final f in ['008_module_corrections.sql', '009_hr_pay_types.sql']) {
      final statements = splitStatements(File('migrations\\$f').readAsStringSync());
      await c.execute('BEGIN');
      try {
        for (final st in statements) {
          await c.execute(st);
        }
        await c.execute('COMMIT');
        print('=== $f bajarildi (${statements.length} statement, COMMIT) ===');
      } catch (e) {
        try { await c.execute('ROLLBACK'); } catch (_) {}
        print('XATO ($f), ROLLBACK: $e');
        rethrow;
      }
      await c.execute('DISCARD ALL');
    }

    Future<void> colInfo(String table, List<String> cols) async {
      for (final name in cols) {
        final r = await c.execute(
            'SELECT data_type FROM information_schema.columns '
            "WHERE table_schema='fh' AND table_name='$table' AND column_name='$name'");
        print('  $table.$name = ${r.isNotEmpty ? r.first[0] : "YOQ"}');
      }
    }

    print('\n--- Tekshirish ---');
    await colInfo('employees', ['pay_type', 'user_id']);
    await colInfo('production_batches', ['employee_id']);
    for (final t in ['piece_rates', 'work_records']) {
      final r = await c.execute(
          "SELECT table_type FROM information_schema.tables WHERE table_schema='fh' AND table_name='$t'");
      print('  $t [${r.isNotEmpty ? r.first[0] : "YOQ"}]');
    }
    final v = await c.execute('SELECT * FROM fh.monthly_payroll_summary LIMIT 1');
    print('  monthly_payroll_summary ustunlari: ${v.isEmpty ? "(bo'sh)" : v.first.schema.columns.map((x) => x.columnName).join(', ')}');
    final mods = await c.execute(
        "SELECT module_key FROM fh.app_modules WHERE module_key IN ('transfer_confirmations','recipes') ORDER BY module_key");
    print('  modullar: ${mods.map((r) => r[0]).join(', ')}');
  } finally {
    await c.close();
  }
}
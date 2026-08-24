import 'dart:io';

import 'package:postgres/postgres.dart';

void main() async {
  var url = Platform.environment['DATABASE_URL']!;
  final uri = Uri.parse(url);
  final ui = uri.userInfo.split(':');
  final conn = await Connection.open(
    Endpoint(
      host: uri.host,
      port: uri.port != 0 ? uri.port : 5432,
      database: uri.pathSegments.first,
      username: ui.first,
      password: ui.length > 1 ? ui.sublist(1).join(':') : null,
    ),
    settings: ConnectionSettings(sslMode: SslMode.require),
  );
  final c = await conn.execute(
    "SELECT COUNT(*), SUM(min_qty) FROM fh.stock_thresholds WHERE item_type='product'",
  );
  stdout.writeln(
      'Product chegara yozuvlari: ${c.first[0]}, jami min_qty: ${c.first[1]}');
  final s = await conn.execute('''
    SELECT t.ref_barcode, p.name, t.min_qty
    FROM fh.stock_thresholds t
    JOIN public.products p ON p.barcode = t.ref_barcode
    ORDER BY t.min_qty DESC LIMIT 5''');
  for (final r in s) {
    final n = r[1] as String;
    stdout.writeln('${r[0]} | ${r[2]} dona | ${n.substring(0, n.length < 55 ? n.length : 55)}');
  }
  await conn.close();
}

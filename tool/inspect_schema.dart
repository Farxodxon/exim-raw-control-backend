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

  stdout.writeln('=== fh.stock_thresholds COLUMNS ===');
  final cols = await conn.execute('''
    SELECT column_name, data_type, is_nullable
    FROM information_schema.columns
    WHERE table_schema='fh' AND table_name='stock_thresholds'
    ORDER BY ordinal_position''');
  for (final r in cols) {
    stdout.writeln('${r[0]} | ${r[1]} | null=${r[2]}');
  }

  stdout.writeln('\n=== public.products COLUMNS ===');
  final pcols = await conn.execute('''
    SELECT column_name, data_type
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='products'
    ORDER BY ordinal_position''');
  for (final r in pcols) {
    stdout.writeln('${r[0]} | ${r[1]}');
  }

  stdout.writeln('\n=== MAHSULOT NOMLARI NAMUNA (har xil guruhdan) ===');
  final names = await conn.execute('''
    SELECT barcode, name, pcs_in_box
    FROM public.products ORDER BY id LIMIT 40''');
  for (final r in names) {
    stdout.writeln('${r[0]} | ${r[1]} | box=${r[2]}');
  }

  await conn.close();
}

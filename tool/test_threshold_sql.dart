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

  final rows = await conn.execute('''
    SELECT t.id,
           t.item_type,
           COALESCE(t.ref_barcode, t.ref_id::text) AS ref_key,
           COALESCE(p.name, rm.name) AS name,
           t.min_qty,
           COALESCE(bal.balance, 0) AS balance
    FROM fh.stock_thresholds t
    LEFT JOIN public.products p
      ON t.item_type = 'product' AND p.barcode = t.ref_barcode
    LEFT JOIN public.raw_materials rm
      ON t.item_type = 'raw_material' AND rm.id = t.ref_id
    LEFT JOIN (
      SELECT item_type,
             COALESCE(ref_barcode, ref_id::text) AS ref_key,
             SUM(CASE direction WHEN 'in' THEN qty ELSE -qty END) AS balance
      FROM fh.stock_ledger
      GROUP BY item_type, COALESCE(ref_barcode, ref_id::text)
    ) bal ON bal.item_type = t.item_type AND bal.ref_key = COALESCE(t.ref_barcode, t.ref_id::text)
    WHERE (\$1::text IS NULL OR t.item_type = \$1)
    ORDER BY (COALESCE(bal.balance, 0) < t.min_qty) DESC, name NULLS LAST
    LIMIT 5
  ''', parameters: [null]);
  stdout.writeln('Qaytarildi: ${rows.length} qator');
  for (final r in rows) {
    stdout.writeln('${r[0]} | ${r[1]} | ${r[4]} | bal=${r[5]}');
  }

  final upd = await conn.execute(
    'UPDATE fh.stock_thresholds SET min_qty = min_qty WHERE id = \$1',
    parameters: [rows.first[0]],
  );
  stdout.writeln('UPDATE affectedRows: ${upd.affectedRows}');

  await conn.close();
}

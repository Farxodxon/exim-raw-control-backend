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
    SELECT barcode, name, pcs_in_box FROM public.products ORDER BY id''');
  final sb = StringBuffer();
  for (final r in rows) {
    sb.writeln('${r[0]}\t${r[2]}\t${r[1]}');
  }
  File(r'D:\Flutter\factory hub\exim-backend\tool\products_dump.txt')
      .writeAsStringSync(sb.toString());
  stdout.writeln('Yozildi: ${rows.length} mahsulot');

  await conn.close();
}

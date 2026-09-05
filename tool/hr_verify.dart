import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';
Future<Connection> connect() async {
  final env = DotEnv()..load();
  String? url = Platform.environment['DATABASE_URL'];
  if (url == null || url.isEmpty) url = env['DATABASE_URL'];
  final uri = Uri.parse(url!);
  final ui = uri.userInfo.split(':');
  return Connection.open(Endpoint(host: uri.host, port: uri.hasPort?uri.port:5432, database: uri.path.substring(1), username: ui.isNotEmpty?ui[0]:null, password: ui.length>1?ui.sublist(1).join(':'):null), settings: ConnectionSettings(sslMode: SslMode.require));
}
void main() async {
  final c = await connect();
  try {
    for (final t in ['employees','attendance','salary_adjustments']) {
      final r = await c.execute("SELECT column_name FROM information_schema.columns WHERE table_schema='fh' AND table_name='${t}' ORDER BY ordinal_position");
      print('=== fh.$t (${r.length} ustun) ===');
      print('  ${r.map((x) => x[0]).join(', ')}');
    }
  } finally { await c.close(); }
}

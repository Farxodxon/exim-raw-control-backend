import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';

class DatabaseConnection {
  static Connection? _connection;
  
  static Future<Connection> getConnection() async {
    if (_connection != null) {
      return _connection!;
    }
    
    // .env faylini yuklash - HUJJATLAR BO'YICHA TO'G'RI USUL
    final env = DotEnv()..load();
    
    // DATABASE_URL ni olish
    String? databaseUrl = Platform.environment['DATABASE_URL'];
    if (databaseUrl == null || databaseUrl.isEmpty) {
      // TO'G'RI: env[] ishlatiladi (dotenv.env EMAS)
      databaseUrl = env['DATABASE_URL'];
    }
    
    if (databaseUrl == null || databaseUrl.isEmpty) {
      throw Exception('DATABASE_URL environment variable not set');
    }
    
    print('Connecting to database...');
    
    final uri = Uri.parse(databaseUrl);
    final host = uri.host;
    final port = uri.hasPort ? uri.port : 5432;
    final database = uri.path.substring(1);
    final userInfo = uri.userInfo.split(':');
    final username = userInfo.isNotEmpty ? userInfo[0] : null;
    final password = userInfo.length > 1 ? userInfo.sublist(1).join(':') : null;
    
    _connection = await Connection.open(
      Endpoint(
        host: host,
        port: port,
        database: database,
        username: username,
        password: password,
      ),
      settings: ConnectionSettings(
        sslMode: SslMode.require,
      ),
    );
    
    print('✅ Connected to PostgreSQL');
    return _connection!;
  }
  
  static Future<void> close() async {
    if (_connection != null) {
      await _connection!.close();
    }
  }
}

import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';

class DatabaseConnection {
  static Connection? _connection;
  static bool _isConnected = false;
  
  static Future<Connection> getConnection() async {
    // Agar ulanish mavjud va ochiq bo‘lsa, qaytaramiz
    if (_connection != null && _isConnected) {
      try {
        // Ulanish hali ishlayotganligini tekshirish
        await _connection!.execute('SELECT 1');
        return _connection!;
      } catch (e) {
        // Ulanish yopilgan, qayta ochamiz
        _isConnected = false;
        _connection = null;
      }
    }
    
    // .env faylini yuklash
    final env = DotEnv()..load();
    
    // DATABASE_URL ni olish
    String? databaseUrl = Platform.environment['DATABASE_URL'];
    if (databaseUrl == null || databaseUrl.isEmpty) {
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
    
    _isConnected = true;
    print('✅ Connected to PostgreSQL');
    return _connection!;
  }
  
  static Future<void> close() async {
    if (_connection != null) {
      await _connection!.close();
      _isConnected = false;
      _connection = null;
    }
  }
}

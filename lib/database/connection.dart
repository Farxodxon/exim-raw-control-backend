// lib/database/connection.dart
import 'package:postgres/postgres.dart';
import 'dart:io';

class DatabaseConnection {
  static Connection? _connection;
  
  static Future<Connection> getConnection() async {
    if (_connection != null && await _connection!.isClosed == false) {
      return _connection!;
    }
    
    final databaseUrl = Platform.environment['DATABASE_URL'];
    if (databaseUrl == null || databaseUrl.isEmpty) {
      throw Exception('DATABASE_URL environment variable not set');
    }
    
    _connection = Connection(
      endpoint: ConnectionEndpoint.fromUri(Uri.parse(databaseUrl)),
      settings: ConnectionSettings(
        sslMode: SslMode.require,
      ),
    );
    
    await _connection!.open();
    print('✅ Connected to Neon.tech PostgreSQL');
    return _connection!;
  }
  
  static Future<void> close() async {
    if (_connection != null) {
      await _connection!.close();
    }
  }
}
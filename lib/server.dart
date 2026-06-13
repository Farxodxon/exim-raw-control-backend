import 'dart:io';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

void main() async {
  print('🚀 Starting Dart Backend Server...');
  
  final router = Router();
  
  router.get('/health', (Request request) async {
    return Response.ok(
      jsonEncode({
        'status': 'ok',
        'timestamp': DateTime.now().toIso8601String(),
        'message': 'Dart backend is running on Render',
      }),
      headers: {'Content-Type': 'application/json'},
    );
  });
  
  router.get('/api/test', (Request request) async {
    return Response.ok(
      jsonEncode({
        'message': 'API is working!',
        'timestamp': DateTime.now().toIso8601String(),
      }),
      headers: {'Content-Type': 'application/json'},
    );
  });
  
  router.get('/', (Request request) async {
    return Response.ok(
      jsonEncode({
        'name': 'Exim Raw Control Backend',
        'version': '1.0.0',
        'status': 'running',
        'endpoints': ['/health', '/api/test'],
      }),
      headers: {'Content-Type': 'application/json'},
    );
  });
  
  // CORS handler
  final handler = (Request request) async {
    if (request.method == 'OPTIONS') {
      return Response.ok('', headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      });
    }
    
    final response = await router(request);
    return response.change(headers: {
      'Access-Control-Allow-Origin': '*',
    });
  };
  
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await shelf_io.serve(handler, '0.0.0.0', port);
  
  print('✅ Server running on port $port');
}

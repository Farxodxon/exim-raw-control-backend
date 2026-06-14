import 'dart:io';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'database/connection.dart';

void main() async {
  print('🚀 Starting Dart Backend Server...');
  
  // Database connection test
  try {
    await DatabaseConnection.getConnection();
  } catch (e) {
    print('⚠️ Database not connected: $e');
  }
  
  final router = Router();
  
  // ============= HEALTH =============
  router.get('/health', (Request request) async {
    bool dbConnected = false;
    try {
      await DatabaseConnection.getConnection();
      dbConnected = true;
    } catch (e) {}
    
    return Response.ok(
      jsonEncode({
        'status': 'ok',
        'database': dbConnected ? 'connected' : 'disconnected',
        'timestamp': DateTime.now().toIso8601String(),
      }),
      headers: {'Content-Type': 'application/json'},
    );
  });
  
  // ============= RAW MATERIALS =============
  router.get('/api/raw-materials', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute('SELECT * FROM raw_materials ORDER BY id');
      
      final materials = result.map((row) => {
        'id': row[0],
        'name': row[1],
        'netto_kg': row[2],
        'brutto_kg': row[3],
        'package_quantity': row[4],
        'current_netto': row[5],
      }).toList();
      
      return Response.ok(
        jsonEncode(materials),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  });
  
  router.post('/api/raw-materials', (Request request) async {
    try {
      final body = jsonDecode(await request.readAsString());
      final conn = await DatabaseConnection.getConnection();
      
      final result = await conn.execute(
        '''
        INSERT INTO raw_materials (name, netto_kg, brutto_kg, package_quantity, current_netto)
        VALUES (\$1, \$2, \$3, \$4, \$5)
        RETURNING *
        ''',
        parameters: [
          Parameter.string(body['name']),
          Parameter.numeric(body['netto_kg']),
          Parameter.numeric(body['brutto_kg']),
          Parameter.integer(body['package_quantity']),
          Parameter.numeric(body['current_netto'] ?? body['netto_kg']),
        ],
      );
      
      final row = result.first;
      return Response.ok(
        jsonEncode({
          'id': row[0],
          'name': row[1],
          'netto_kg': row[2],
          'brutto_kg': row[3],
          'package_quantity': row[4],
          'current_netto': row[5],
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  });
  
  // ============= PRODUCTS =============
  router.get('/api/products', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute('SELECT * FROM products ORDER BY id');
      
      final products = result.map((row) => ({
        'id': row[0],
        'barcode': row[1],
        'name': row[2],
        'category': row[3],
        'tnved': row[4],
        'pcs_in_box': row[5],
        'price_usd': row[6],
        'netto_per_piece': row[7],
      })).toList();
      
      return Response.ok(
        jsonEncode(products),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  });
  
  router.get('/api/products/barcode/<barcode>', (Request request, String barcode) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        'SELECT * FROM products WHERE barcode = \$1',
        parameters: [Parameter.string(barcode)],
      );
      
      if (result.isEmpty) {
        return Response.notFound(
          body: jsonEncode({'error': 'Product not found'}),
        );
      }
      
      final row = result.first;
      return Response.ok(
        jsonEncode({
          'id': row[0],
          'barcode': row[1],
          'name': row[2],
          'category': row[3],
          'tnved': row[4],
          'pcs_in_box': row[5],
          'price_usd': row[6],
          'netto_per_piece': row[7],
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  });
  
  // ============= CORS =============
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
  
  // Start server
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await shelf_io.serve(handler, '0.0.0.0', port);
  
  print('✅ Server running on http://0.0.0.0:$port');
  print('📊 Health check: http://localhost:$port/health');
  print('📦 Raw materials: http://localhost:$port/api/raw-materials');
  print('📦 Products: http://localhost:$port/api/products');
}
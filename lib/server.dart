import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'database/connection.dart';

void main() async {
  print('🚀 Starting Dart Backend Server...');
  
  // Database ulanishini test qilish
  try {
    final conn = await DatabaseConnection.getConnection();
    final result = await conn.execute('SELECT NOW()');
    print('✅ Database time: ${result.first[0]}');
  } catch (e) {
    print('⚠️ Database connection failed: $e');
  }
  
  final router = Router();
  
  // Health check
  router.get('/health', (Request request) {
    return Response.ok(
      jsonEncode({'status': 'ok', 'message': 'Server is running'}),
      headers: {'Content-Type': 'application/json'},
    );
  });
  
  // Test API
  router.get('/api/test', (Request request) {
    return Response.ok(
      jsonEncode({'message': 'API test is working!'}),
      headers: {'Content-Type': 'application/json'},
    );
  });
  
  // GET all raw materials
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
  
  // POST new raw material
  router.post('/api/raw-materials', (Request request) async {
    try {
      final body = jsonDecode(await request.readAsString());
      final conn = await DatabaseConnection.getConnection();
      
      final sql = '''
        INSERT INTO raw_materials (name, netto_kg, brutto_kg, package_quantity, current_netto)
        VALUES ('${body['name']}', ${body['netto_kg']}, ${body['brutto_kg']}, ${body['package_quantity']}, ${body['current_netto'] ?? body['netto_kg']})
        RETURNING *
      ''';
      
      final result = await conn.execute(sql);
      
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
  
  // CORS handler
  final handler = (Request request) async {
    if (request.method == 'OPTIONS') {
      return Response.ok('', headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      });
    }
    final response = await router(request);
    return response.change(headers: {
      'Access-Control-Allow-Origin': '*',
    });
  };
  

  router.post('/api/orders/check', (Request request) async {
  try {
    final body = jsonDecode(await request.readAsString());
    final barcodes = List<String>.from(body['barcodes']);

    final conn = await DatabaseConnection.getConnection();
    final results = [];

    for (final barcode in barcodes) {
      final result = await conn.execute(
        'SELECT * FROM products WHERE barcode = \$1',
        parameters: [barcode],
      );
      
      if (result.isNotEmpty) {
        final row = result.first;
        results.add({
          'barcode': barcode,
          'found': true,
          'product': {
            'id': row[0],
            'barcode': row[1],
            'name': row[2],
            'category': row[3],
            'tnved': row[4],
            'pcs_in_box': row[5],
            'price_usd': row[6],
            'netto_per_piece': row[7],
          }
        });
      } else {
        results.add({
          'barcode': barcode,
          'found': false,
        });
      }
    }

    return Response.ok(
      jsonEncode({
        'total': barcodes.length,
        'found': results.where((r) => r['found'] == true).length,
        'not_found': results.where((r) => r['found'] == false).length,
        'results': results,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'error': e.toString()}),
    );
  }
});
  // Serverni ishga tushirish - '_' bilan almashtiramiz (warning yo'qoladi)
  final _ = await shelf_io.serve(handler, '0.0.0.0', 8080);
  print('✅ Server running on http://localhost:8080');
  print('📊 Health: http://localhost:8080/health');
  print('🧪 Test: http://localhost:8080/api/test');
  print('📦 Raw materials: http://localhost:8080/api/raw-materials');
}
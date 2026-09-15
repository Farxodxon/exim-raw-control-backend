import 'dart:io';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dotenv/dotenv.dart';

class FhJwt {
  static DotEnv get _env => DotEnv()..load();

  static String get _secret {
    final secret = Platform.environment['JWT_SECRET'] ?? _env['JWT_SECRET'];
    if (secret == null || secret.isEmpty) {
      throw Exception('JWT_SECRET environment variable sozlanmagan! .env faylini tekshiring');
    }
    return secret;
  }

  static String get setupSecretKey =>
      Platform.environment['SETUP_SECRET_KEY'] ?? (_env['SETUP_SECRET_KEY'] ?? '');

  static const Duration _expiry = Duration(hours: 24);

  static String generateToken({
    required int userId,
    required String email,
    required String role,
  }) {
    final jwt = JWT({
      'user_id': userId,
      'email': email,
      'role': role,
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'exp': DateTime.now().add(_expiry).millisecondsSinceEpoch ~/ 1000,
    });

    return jwt.sign(SecretKey(_secret));
  }

  static Map<String, dynamic>? verifyToken(String token) {
    try {
      final jwt = JWT.verify(token, SecretKey(_secret));
      return jwt.payload as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? getUserFromToken(String? authHeader) {
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return null;
    }
    return verifyToken(authHeader.substring(7));
  }
}

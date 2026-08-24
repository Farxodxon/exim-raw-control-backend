import 'package:bcrypt/bcrypt.dart';
import '../factoryhub/policy.dart';
import '../database/connection.dart';
import '../factoryhub/user.dart';

class FhUserStorage {
  static const String _select =
      'SELECT id, username, email, COALESCE(role, \'warehouse_keeper\'), '
      'COALESCE(is_active, true), created_at FROM fh.users';

  static Future<User?> login(String email, String password) async {
    final db = await DatabaseConnection.getConnection();
    try {
      final result = await db.execute(
        'SELECT id, username, email, COALESCE(role, \'warehouse_keeper\'), '
        'COALESCE(is_active, true), created_at, password FROM fh.users WHERE email = \$1',
        parameters: [email],
      );
      if (result.isEmpty) return null;

      final row = result.first;
      final isActive = row[4] as bool? ?? true;
      if (!isActive) return null;

      final storedPassword = row[6] as String;
      bool passwordMatch = false;
      if (storedPassword.startsWith('\$2')) {
        passwordMatch = BCrypt.checkpw(password, storedPassword);
      } else {
        passwordMatch = storedPassword == password;
        if (passwordMatch) {
          final hashed = BCrypt.hashpw(password, BCrypt.gensalt());
          await db.execute(
            'UPDATE fh.users SET password = \$1 WHERE id = \$2',
            parameters: [hashed, row[0]],
          );
        }
      }

      if (!passwordMatch) return null;
      return _rowToUser(row);
    } catch (e) {
      print('Login xatosi: $e');
      return null;
    }
  }

  static Future<User?> createFirstAdmin(
      String username, String email, String password) async {
    final db = await DatabaseConnection.getConnection();
    try {
      final existing = await db.execute(
        "SELECT id FROM fh.users WHERE role = 'admin' LIMIT 1",
      );
      if (existing.isNotEmpty) return null;

      final hashedPassword = BCrypt.hashpw(password, BCrypt.gensalt());
      final result = await db.execute(
        'INSERT INTO fh.users (username, email, password, role) '
        'VALUES (\$1, \$2, \$3, \'${AppRoles.admin}\') '
        'RETURNING id, username, email, role, COALESCE(is_active, true), created_at',
        parameters: [username, email, hashedPassword],
      );
      return _rowToUser(result.first);
    } catch (e) {
      print('createFirstAdmin xatosi: $e');
      return null;
    }
  }

  static Future<User?> createUser({
    required String username,
    required String email,
    required String password,
    required String role,
  }) async {
    if (!AppRoles.isValid(role)) return null;

    final db = await DatabaseConnection.getConnection();
    try {
      final existing = await db.execute(
        'SELECT id FROM fh.users WHERE email = \$1',
        parameters: [email],
      );
      if (existing.isNotEmpty) return null;

      final hashedPassword = BCrypt.hashpw(password, BCrypt.gensalt());
      final result = await db.execute(
        'INSERT INTO fh.users (username, email, password, role) '
        'VALUES (\$1, \$2, \$3, \$4) '
        'RETURNING id, username, email, role, COALESCE(is_active, true), created_at',
        parameters: [username, email, hashedPassword, role],
      );
      return _rowToUser(result.first);
    } catch (e) {
      print('createUser xatosi: $e');
      return null;
    }
  }

  static Future<List<User>> getAll({String? role}) async {
    final db = await DatabaseConnection.getConnection();
    try {
      var query = _select;
      final params = <dynamic>[];

      if (role != null) {
        query += ' WHERE role = \$1';
        params.add(role);
      }
      query += ' ORDER BY id';

      final result = params.isEmpty
          ? await db.execute(query)
          : await db.execute(query, parameters: params);

      return result.map(_rowToUser).toList();
    } catch (e) {
      print('getAll xatosi: $e');
      return [];
    }
  }

  static Future<User?> update(
    int id, {
    String? username,
    String? email,
    String? password,
    String? role,
    bool? isActive,
  }) async {
    final db = await DatabaseConnection.getConnection();
    try {
      if (role != null && !AppRoles.isValid(role)) return null;

      final setParts = <String>[];
      final params = <dynamic>[];
      var idx = 1;

      void add(String column, dynamic value) {
        setParts.add('$column = \$$idx');
        params.add(value);
        idx++;
      }

      if (username != null) add('username', username);
      if (email != null) add('email', email);
      if (password != null) add('password', BCrypt.hashpw(password, BCrypt.gensalt()));
      if (role != null) add('role', role);
      if (isActive != null) add('is_active', isActive);

      if (setParts.isEmpty) return null;
      params.add(id);

      final result = await db.execute(
        'UPDATE fh.users SET ${setParts.join(', ')} WHERE id = \$$idx '
        'RETURNING id, username, email, COALESCE(role, \'warehouse_keeper\'), '
        'COALESCE(is_active, true), created_at',
        parameters: params,
      );

      if (result.isEmpty) return null;
      return _rowToUser(result.first);
    } catch (_) {
      return null;
    }
  }

  static User _rowToUser(dynamic row) {
    return User(
      id: int.parse(row[0].toString()),
      username: row[1] as String,
      email: row[2] as String,
      role: row[3] as String,
      isActive: row[4] as bool? ?? true,
      createdAt: row[5] as DateTime,
    );
  }
}

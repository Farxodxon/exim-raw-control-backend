class User {
  final int id;
  final String username;
  final String email;
  final String role;
  final bool isActive;
  final DateTime createdAt;

  User({
    required this.id,
    required this.username,
    required this.email,
    required this.role,
    this.isActive = true,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'role': role,
      'isActive': isActive,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}

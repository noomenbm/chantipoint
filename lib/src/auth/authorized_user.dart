enum AuthorizedRole {
  employee,
  administrator;

  static AuthorizedRole? fromDatabase(String value) {
    return switch (value) {
      'employee' => AuthorizedRole.employee,
      'administrator' => AuthorizedRole.administrator,
      _ => null,
    };
  }

  String get frenchLabel {
    return switch (this) {
      AuthorizedRole.employee => 'Employé',
      AuthorizedRole.administrator => 'Administrateur',
    };
  }
}

class AuthorizedUser {
  const AuthorizedUser({
    required this.profileId,
    required this.companyId,
    required this.displayName,
    required this.email,
    required this.roles,
  });

  final String profileId;
  final String companyId;
  final String displayName;
  final String email;
  final Set<AuthorizedRole> roles;

  bool get canAccessApplication => roles.isNotEmpty;
}

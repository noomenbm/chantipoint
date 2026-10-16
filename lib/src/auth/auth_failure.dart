enum AuthFailureKind {
  invalidCredentials,
  accessDenied,
  sessionExpired,
  network,
  serviceUnavailable,
  unknown,
}

class AuthFailure implements Exception {
  const AuthFailure(this.kind);

  final AuthFailureKind kind;

  String get userMessage {
    return switch (kind) {
      AuthFailureKind.invalidCredentials =>
        'Adresse courriel ou mot de passe invalide.',
      AuthFailureKind.accessDenied =>
        "Ce compte n'est pas autorisé à accéder à ChantiPoint.",
      AuthFailureKind.sessionExpired =>
        'Votre session a expiré. Veuillez vous reconnecter.',
      AuthFailureKind.network =>
        'Connexion impossible. Vérifiez votre réseau et réessayez.',
      AuthFailureKind.serviceUnavailable =>
        'Service temporairement indisponible. Réessayez dans un moment.',
      AuthFailureKind.unknown =>
        'Connexion impossible pour le moment. Réessayez plus tard.',
    };
  }
}

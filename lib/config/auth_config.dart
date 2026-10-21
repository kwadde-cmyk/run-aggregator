// Put your real Client ID and Secret here locally.
// Do NOT commit the secret to the repo.
// For now use the Web client you created.

class AuthConfig {
  static const String googleHealthClientId =
      '24711413447-q53918n750ps3b8klk3lrhe0v7ddfqpm.apps.googleusercontent.com';

  // TODO: Set this locally, never commit the real value
  static const String googleHealthClientSecret = 'YOUR_CLIENT_SECRET_HERE';

  static const String googleHealthRedirectUri =
      'de.kwadde.runaggregator:/oauthredirect'; // Custom scheme for Android

  static const List<String> googleHealthScopes = [
    'openid',
    'email',
    'https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly',
    'https://www.googleapis.com/auth/googlehealth.location.readonly',
    'https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly',
  ];
}

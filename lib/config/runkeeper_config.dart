// ASICS Runkeeper OAuth config.
// Register an app at https://runkeeper.com/partner/applications
// Then fill in Client ID and Secret locally (do not commit secrets).

class RunkeeperConfig {
  static const String clientId = 'YOUR_RUNKEEPER_CLIENT_ID';
  static const String clientSecret = 'YOUR_RUNKEEPER_CLIENT_SECRET';

  static const String redirectUri = 'de.kwadde.runaggregator:/oauthredirect';

  static const String authorizeUrl = 'https://runkeeper.com/apps/authorize';
  static const String tokenUrl = 'https://runkeeper.com/apps/token';
  static const String apiBaseUrl = 'https://api.runkeeper.com';

  static const List<String> scopes = ['read_all'];
}

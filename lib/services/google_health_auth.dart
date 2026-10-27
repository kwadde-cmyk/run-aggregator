import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config/auth_config.dart';

class GoogleHealthAuth {
  static const FlutterAppAuth _appAuth = FlutterAppAuth();
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static const _accessTokenKey = 'google_health_access_token';
  static const _refreshTokenKey = 'google_health_refresh_token';

  static Future<bool> login() async {
    try {
      final result = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          AuthConfig.googleHealthClientId,
          AuthConfig.googleHealthRedirectUri,
          clientSecret: AuthConfig.googleHealthClientSecret,
          scopes: AuthConfig.googleHealthScopes,
          serviceConfiguration: const AuthorizationServiceConfiguration(
            authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
            tokenEndpoint: 'https://oauth2.googleapis.com/token',
          ),
        ),
      );

      // ignore: unnecessary_null_comparison
      if (result != null) {
        await _storage.write(key: _accessTokenKey, value: result.accessToken);
        if (result.refreshToken != null) {
          await _storage.write(key: _refreshTokenKey, value: result.refreshToken);
        }
        return true;
      }
      return false;
    } catch (e) {
      // ignore: avoid_print
      print('Google Health login error: $e');
      return false;
    }
  }

  static Future<String?> getAccessToken() async {
    return _storage.read(key: _accessTokenKey);
  }

  static Future<void> logout() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
  }

  static Future<bool> isLoggedIn() async {
    final token = await getAccessToken();
    return token != null && token.isNotEmpty;
  }
}

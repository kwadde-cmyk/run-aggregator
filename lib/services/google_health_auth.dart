import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/auth_config.dart';
import 'google_health_session.dart';

export 'google_health_session.dart' show googleHealthErrorRequiresLogin;

const googleHealthServiceConfiguration = AuthorizationServiceConfiguration(
  authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
  tokenEndpoint: 'https://oauth2.googleapis.com/token',
);

/// Same client secret the working sign-in already sends, including when it
/// is empty. AppAuth treats null and "" differently (no client auth versus
/// HTTP Basic), so refresh must keep the value that code exchange already uses.
String googleHealthClientSecret() => AuthConfig.googleHealthClientSecret;

/// Authorization request that asks Google for a refresh token.
///
/// `access_type=offline` is what makes Google return a refresh token (the
/// default is `online`, which returns only an hour-long access token).
/// `prompt=consent` is required on later logins, otherwise Google omits the
/// refresh token because the user already approved the scopes.
AuthorizationTokenRequest googleHealthAuthorizationRequest() {
  return AuthorizationTokenRequest(
    AuthConfig.googleHealthClientId,
    AuthConfig.googleHealthRedirectUri,
    clientSecret: googleHealthClientSecret(),
    scopes: AuthConfig.googleHealthScopes,
    promptValues: const ['consent'],
    additionalParameters: const {
      'access_type': 'offline',
      'include_granted_scopes': 'true',
    },
    serviceConfiguration: googleHealthServiceConfiguration,
  );
}

TokenRequest googleHealthRefreshRequest(String refreshToken) {
  return TokenRequest(
    AuthConfig.googleHealthClientId,
    AuthConfig.googleHealthRedirectUri,
    clientSecret: googleHealthClientSecret(),
    refreshToken: refreshToken,
    serviceConfiguration: googleHealthServiceConfiguration,
  );
}

/// Maps an AppAuth / token-endpoint failure to a session error.
///
/// Only `invalid_grant` (refresh token expired or revoked) ends the session.
/// Network and configuration errors keep the stored refresh token.
GoogleOAuthException googleOAuthFailure(Object error) {
  String? oauthError;
  String? description;
  if (error is FlutterAppAuthPlatformException) {
    oauthError = error.platformErrorDetails.error;
    description = error.platformErrorDetails.errorDescription;
  }
  final blob = '${oauthError ?? ''} ${description ?? ''} $error'.toLowerCase();
  final revoked = oauthError == FlutterAppAuthOAuthError.invalidGrant ||
      oauthError == 'invalid_token' ||
      blob.contains('invalid_grant') ||
      blob.contains('token has been expired or revoked');
  final message = error is FlutterAppAuthPlatformException
      ? (error.message ?? oauthError ?? 'Google token request failed')
      : error.toString();
  return GoogleOAuthException(message, revoked: revoked, cause: error);
}

/// Keys already used by previous builds. Do not rename them: existing
/// installs still have the access token (and sometimes a refresh token) here.
class StoredGoogleTokens {
  static const accessKey = 'google_health_access_token';
  static const refreshKey = 'google_health_refresh_token';
  static const expiryKey = 'google_health_access_token_expiry';

  static OAuthTokens decode(String? access, String? refresh, String? expiry) {
    return OAuthTokens(
      accessToken: _blankToNull(access),
      refreshToken: _blankToNull(refresh),
      accessTokenExpiry:
          expiry == null || expiry.isEmpty ? null : DateTime.tryParse(expiry),
    );
  }

  static Map<String, String?> encode(OAuthTokens tokens) {
    return {
      accessKey: _blankToNull(tokens.accessToken),
      refreshKey: _blankToNull(tokens.refreshToken),
      expiryKey: tokens.accessTokenExpiry?.toUtc().toIso8601String(),
    };
  }

  static String? _blankToNull(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }
}

class SecureGoogleTokenStore implements GoogleTokenStore {
  SecureGoogleTokenStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<OAuthTokens> read() async {
    return StoredGoogleTokens.decode(
      await _storage.read(key: StoredGoogleTokens.accessKey),
      await _storage.read(key: StoredGoogleTokens.refreshKey),
      await _storage.read(key: StoredGoogleTokens.expiryKey),
    );
  }

  @override
  Future<void> write(OAuthTokens tokens) async {
    final encoded = StoredGoogleTokens.encode(tokens);
    for (final entry in encoded.entries) {
      await _storage.write(key: entry.key, value: entry.value);
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: StoredGoogleTokens.accessKey);
    await _storage.delete(key: StoredGoogleTokens.refreshKey);
    await _storage.delete(key: StoredGoogleTokens.expiryKey);
  }
}

class AppAuthGoogleOAuth implements GoogleOAuthApi {
  AppAuthGoogleOAuth(this._appAuth);

  final FlutterAppAuth _appAuth;

  @override
  Future<OAuthTokens?> authorizeInteractive() async {
    try {
      final result = await _appAuth.authorizeAndExchangeCode(
        googleHealthAuthorizationRequest(),
      );
      final tokens = OAuthTokens(
        accessToken: result.accessToken,
        refreshToken: result.refreshToken,
        accessTokenExpiry: result.accessTokenExpirationDateTime,
      );
      if (tokens.hasAccess && !tokens.hasRefresh) {
        // ignore: avoid_print
        print(
          'Google Health login did not return a refresh token. '
          'The session cannot outlive the access token.',
        );
      }
      return tokens;
    } on FlutterAppAuthUserCancelledException {
      return null;
    } catch (error) {
      // ignore: avoid_print
      print('Google Health login error: $error');
      throw googleOAuthFailure(error);
    }
  }

  @override
  Future<OAuthTokens> refresh(String refreshToken) async {
    try {
      final result = await _appAuth.token(
        googleHealthRefreshRequest(refreshToken),
      );
      return OAuthTokens(
        accessToken: result.accessToken,
        refreshToken: result.refreshToken,
        accessTokenExpiry: result.accessTokenExpirationDateTime,
      );
    } catch (error) {
      // ignore: avoid_print
      print('Google Health token refresh error: $error');
      throw googleOAuthFailure(error);
    }
  }
}

class GoogleHealthAuth {
  static const FlutterAppAuth _appAuth = FlutterAppAuth();
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static GoogleHealthSession? _override;
  static GoogleHealthSession? _default;

  static GoogleHealthSession get session {
    final override = _override;
    if (override != null) return override;
    return _default ??= GoogleHealthSession(
      store: SecureGoogleTokenStore(_storage),
      oauth: AppAuthGoogleOAuth(_appAuth),
    );
  }

  @visibleForTesting
  static void debugSetSession(GoogleHealthSession? value) {
    _override = value;
  }

  static Future<bool> login() async {
    try {
      return await session.login();
    } catch (error) {
      // ignore: avoid_print
      print('Google Health login error: $error');
      return false;
    }
  }

  static Future<String> getAccessToken({bool forceRefresh = false}) {
    return session.getAccessToken(forceRefresh: forceRefresh);
  }

  static Future<void> logout() => session.logout();

  static Future<bool> isLoggedIn() => session.isLoggedIn();
}

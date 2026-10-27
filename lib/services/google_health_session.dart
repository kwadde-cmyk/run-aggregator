import 'dart:async';

/// Tokens for the Google Health OAuth session.
class OAuthTokens {
  const OAuthTokens({
    this.accessToken,
    this.refreshToken,
    this.accessTokenExpiry,
  });

  final String? accessToken;
  final String? refreshToken;
  final DateTime? accessTokenExpiry;

  static const empty = OAuthTokens();

  bool get hasAccess => accessToken != null && accessToken!.isNotEmpty;

  bool get hasRefresh => refreshToken != null && refreshToken!.isNotEmpty;

  /// A stored access token with no expiry is treated as still usable.
  /// Callers that receive HTTP 401 must force a refresh.
  bool accessValidAt(
    DateTime now, {
    Duration leeway = const Duration(seconds: 60),
  }) {
    if (!hasAccess) return false;
    final expiry = accessTokenExpiry;
    if (expiry == null) return true;
    return expiry.isAfter(now.add(leeway));
  }
}

/// Raised when the refresh token is missing, expired, or revoked.
/// The string form contains `UNAUTHENTICATED` so the UI can return to login.
class GoogleSessionExpired implements Exception {
  GoogleSessionExpired([this.message = 'Google session expired']);

  final String message;

  @override
  String toString() => 'UNAUTHENTICATED: $message';
}

/// Failure from the Google token endpoint or the interactive login.
class GoogleOAuthException implements Exception {
  GoogleOAuthException(this.message, {this.revoked = false, this.cause});

  final String message;

  /// True only when the refresh token itself can no longer be used.
  final bool revoked;

  final Object? cause;

  @override
  String toString() => 'GoogleOAuthException: $message';
}

abstract class GoogleTokenStore {
  Future<OAuthTokens> read();

  Future<void> write(OAuthTokens tokens);

  Future<void> clear();
}

abstract class GoogleOAuthApi {
  /// Null when the user cancels the browser. Throws [GoogleOAuthException]
  /// when Google rejects the login.
  Future<OAuthTokens?> authorizeInteractive();

  Future<OAuthTokens> refresh(String refreshToken);
}

/// Decides when a stored Google session can be reused and when it must be
/// refreshed. Interactive login is required only after the refresh token is
/// gone or Google rejects it.
class GoogleHealthSession {
  GoogleHealthSession({
    required this.store,
    required this.oauth,
    DateTime Function()? now,
    this.leeway = const Duration(seconds: 60),
    this.fallbackAccessTokenLifetime = const Duration(minutes: 50),
  }) : now = now ?? DateTime.now;

  final GoogleTokenStore store;
  final GoogleOAuthApi oauth;
  final DateTime Function() now;
  final Duration leeway;
  final Duration fallbackAccessTokenLifetime;

  Future<void> _queue = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<bool> login() {
    return _locked(() async {
      final tokens = await oauth.authorizeInteractive();
      if (tokens == null || !tokens.hasAccess) return false;
      await store.write(_issued(tokens));
      return true;
    });
  }

  Future<void> logout() {
    return _locked(store.clear);
  }

  /// True when a later API call can obtain an access token without showing
  /// the login screen.
  Future<bool> isLoggedIn() {
    return _locked(() async {
      final tokens = await store.read();
      if (tokens.hasRefresh) return true;
      return tokens.accessValidAt(now(), leeway: leeway);
    });
  }

  /// Returns a bearer token, refreshing it when it is missing, near expiry,
  /// or [forceRefresh] is set after the API rejected the previous one.
  Future<String> getAccessToken({bool forceRefresh = false}) {
    return _locked(() => _getAccessToken(forceRefresh: forceRefresh));
  }

  Future<String> _getAccessToken({required bool forceRefresh}) async {
    final current = await store.read();
    if (!forceRefresh && current.accessValidAt(now(), leeway: leeway)) {
      return current.accessToken!;
    }
    if (!current.hasRefresh) {
      await store.clear();
      throw GoogleSessionExpired(
        forceRefresh
            ? 'Access token was rejected and no refresh token is stored'
            : 'No refresh token is stored',
      );
    }

    try {
      final refreshed = await oauth.refresh(current.refreshToken!);
      if (!refreshed.hasAccess) {
        throw GoogleOAuthException(
          'Refresh response did not include an access token',
        );
      }
      final merged = OAuthTokens(
        accessToken: refreshed.accessToken,
        refreshToken: refreshed.hasRefresh
            ? refreshed.refreshToken
            : current.refreshToken,
        accessTokenExpiry: _expiryOrFallback(refreshed.accessTokenExpiry),
      );
      await store.write(merged);
      return merged.accessToken!;
    } on GoogleOAuthException catch (error) {
      if (error.revoked) {
        await store.clear();
        throw GoogleSessionExpired(error.message);
      }
      rethrow;
    }
  }

  OAuthTokens _issued(OAuthTokens tokens) {
    return OAuthTokens(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      accessTokenExpiry: _expiryOrFallback(tokens.accessTokenExpiry),
    );
  }

  DateTime _expiryOrFallback(DateTime? expiry) {
    return expiry ?? now().add(fallbackAccessTokenLifetime);
  }
}

/// UI helper: only a dead session should send the user back to login.
bool googleHealthErrorRequiresLogin(Object error) {
  return error.toString().contains('UNAUTHENTICATED');
}

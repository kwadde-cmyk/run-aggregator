import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_aggregator/services/google_health_auth.dart';
import 'package:run_aggregator/services/google_health_session.dart';

void main() {
  group('StoredGoogleTokens', () {
    test('keeps the storage keys previous installs already use', () {
      expect(StoredGoogleTokens.accessKey, 'google_health_access_token');
      expect(StoredGoogleTokens.refreshKey, 'google_health_refresh_token');
      expect(
        StoredGoogleTokens.expiryKey,
        'google_health_access_token_expiry',
      );
    });

    test('round-trips tokens and drops blank values', () {
      final expiry = DateTime.utc(2026, 5, 1, 8, 30);
      final encoded = StoredGoogleTokens.encode(
        OAuthTokens(
          accessToken: 'access',
          refreshToken: 'refresh',
          accessTokenExpiry: expiry,
        ),
      );

      final decoded = StoredGoogleTokens.decode(
        encoded[StoredGoogleTokens.accessKey],
        encoded[StoredGoogleTokens.refreshKey],
        encoded[StoredGoogleTokens.expiryKey],
      );

      expect(decoded.accessToken, 'access');
      expect(decoded.refreshToken, 'refresh');
      expect(decoded.accessTokenExpiry, expiry);

      final blank = StoredGoogleTokens.decode('', null, '');
      expect(blank.hasAccess, isFalse);
      expect(blank.hasRefresh, isFalse);
      expect(blank.accessTokenExpiry, isNull);
    });
  });

  group('Google OAuth request', () {
    test('interactive login asks Google for a refresh token', () {
      final request = googleHealthAuthorizationRequest();

      expect(request.additionalParameters?['access_type'], 'offline');
      expect(request.additionalParameters?['include_granted_scopes'], 'true');
      expect(request.promptValues, ['consent']);
      expect(request.clientSecret, '');
      expect(
        request.serviceConfiguration?.tokenEndpoint,
        'https://oauth2.googleapis.com/token',
      );
      expect(
        request.scopes,
        contains(
          'https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly',
        ),
      );
    });

    test('refresh uses the refresh token and does not repeat consent params',
        () {
      final request = googleHealthRefreshRequest('refresh-1');

      expect(request.refreshToken, 'refresh-1');
      expect(request.scopes, isNull);
      expect(request.additionalParameters, isNull);
      expect(request.clientSecret, '');
      expect(googleHealthClientSecret(), '');
    });
  });

  group('googleOAuthFailure', () {
    test('invalid_grant ends the session', () {
      final failure = googleOAuthFailure(
        FlutterAppAuthPlatformException(
          code: 'token_failed',
          message:
              'Failed to get token: [error: invalid_grant, description: Token has been expired or revoked.]',
          platformErrorDetails: FlutterAppAuthPlatformErrorDetails(
            error: 'invalid_grant',
            errorDescription: 'Token has been expired or revoked.',
          ),
        ),
      );

      expect(failure.revoked, isTrue);
    });

    test('invalid_client and network errors keep the refresh token', () {
      final client = googleOAuthFailure(
        FlutterAppAuthPlatformException(
          code: 'token_failed',
          message:
              'Failed to get token: [error: invalid_client, description: bad]',
          platformErrorDetails: FlutterAppAuthPlatformErrorDetails(
            error: 'invalid_client',
            errorDescription: 'The OAuth client was not found.',
          ),
        ),
      );
      final offline = googleOAuthFailure(
        Exception('SocketException: Failed host lookup'),
      );

      expect(client.revoked, isFalse);
      expect(offline.revoked, isFalse);
    });
  });

  group('googleHealthErrorRequiresLogin', () {
    test('only a dead session sends the user to the login screen', () {
      expect(
        googleHealthErrorRequiresLogin(Exception('UNAUTHENTICATED')),
        isTrue,
      );
      expect(googleHealthErrorRequiresLogin(GoogleSessionExpired()), isTrue);
      expect(
        googleHealthErrorRequiresLogin(
          Exception('Failed to load exercises: 401 no'),
        ),
        isFalse,
      );
      expect(
        googleHealthErrorRequiresLogin(GoogleOAuthException('offline')),
        isFalse,
      );
    });
  });

  group('GoogleHealthSession', () {
    late DateTime clock;
    late MemoryTokenStore store;
    late FakeOAuth oauth;
    late GoogleHealthSession session;

    setUp(() {
      clock = DateTime.utc(2026, 1, 1, 12);
      store = MemoryTokenStore();
      oauth = FakeOAuth();
      session = GoogleHealthSession(
        store: store,
        oauth: oauth,
        now: () => clock,
      );
    });

    test('login stores access token, refresh token, and expiry', () async {
      final expiry = clock.add(const Duration(hours: 1));
      oauth.onAuthorize = () async => OAuthTokens(
            accessToken: 'access',
            refreshToken: 'refresh',
            accessTokenExpiry: expiry,
          );

      expect(await session.login(), isTrue);

      final stored = await store.read();
      expect(stored.accessToken, 'access');
      expect(stored.refreshToken, 'refresh');
      expect(stored.accessTokenExpiry, expiry);
      expect(await session.isLoggedIn(), isTrue);
    });

    test('login without an expiry still gets a refresh window', () async {
      oauth.onAuthorize = () async => const OAuthTokens(
            accessToken: 'access',
            refreshToken: 'refresh',
          );

      expect(await session.login(), isTrue);
      expect(
        (await store.read()).accessTokenExpiry,
        clock.add(const Duration(minutes: 50)),
      );
    });

    test('cancelled login does not erase a stored session', () async {
      store.tokens = OAuthTokens(
        accessToken: 'access',
        refreshToken: 'refresh',
        accessTokenExpiry: clock.add(const Duration(hours: 1)),
      );
      oauth.onAuthorize = () async => null;

      expect(await session.login(), isFalse);
      expect((await store.read()).refreshToken, 'refresh');
    });

    test('a fresh access token is reused', () async {
      store.tokens = OAuthTokens(
        accessToken: 'access',
        refreshToken: 'refresh',
        accessTokenExpiry: clock.add(const Duration(minutes: 30)),
      );

      expect(await session.getAccessToken(), 'access');
      expect(oauth.refreshes, 0);
    });

    test('an access token inside the leeway is refreshed', () async {
      store.tokens = OAuthTokens(
        accessToken: 'old',
        refreshToken: 'refresh',
        accessTokenExpiry: clock.add(const Duration(seconds: 60)),
      );
      oauth.onRefresh = (refreshToken) async => OAuthTokens(
            accessToken: 'new',
            accessTokenExpiry: clock.add(const Duration(hours: 1)),
          );

      expect(await session.getAccessToken(), 'new');
      expect(oauth.refreshes, 1);
      expect((await store.read()).refreshToken, 'refresh');
    });

    test(
        'expired access token is refreshed and a rotated refresh token is kept',
        () async {
      store.tokens = OAuthTokens(
        accessToken: 'old',
        refreshToken: 'old-refresh',
        accessTokenExpiry: clock.subtract(const Duration(minutes: 1)),
      );
      oauth.onRefresh = (refreshToken) async {
        expect(refreshToken, 'old-refresh');
        return OAuthTokens(
          accessToken: 'new',
          refreshToken: 'new-refresh',
          accessTokenExpiry: clock.add(const Duration(hours: 1)),
        );
      };

      expect(await session.getAccessToken(), 'new');
      final stored = await store.read();
      expect(stored.accessToken, 'new');
      expect(stored.refreshToken, 'new-refresh');
    });

    test('refresh token alone still counts as logged in and is exchanged',
        () async {
      store.tokens = const OAuthTokens(refreshToken: 'refresh');
      oauth.onRefresh = (_) async => OAuthTokens(
            accessToken: 'new',
            accessTokenExpiry: clock.add(const Duration(hours: 1)),
          );

      expect(await session.isLoggedIn(), isTrue);
      expect(await session.getAccessToken(), 'new');
    });

    test('legacy access token without expiry is used until a forced refresh',
        () async {
      store.tokens = const OAuthTokens(accessToken: 'legacy');

      expect(await session.isLoggedIn(), isTrue);
      expect(await session.getAccessToken(), 'legacy');
      expect(oauth.refreshes, 0);

      await expectLater(
        session.getAccessToken(forceRefresh: true),
        throwsA(isA<GoogleSessionExpired>()),
      );
      expect(await session.isLoggedIn(), isFalse);
      expect((await store.read()).hasAccess, isFalse);
    });

    test('revoked refresh token clears the session', () async {
      store.tokens = OAuthTokens(
        accessToken: 'old',
        refreshToken: 'refresh',
        accessTokenExpiry: clock.subtract(const Duration(hours: 2)),
      );
      oauth.onRefresh = (_) async => throw GoogleOAuthException(
            'invalid_grant',
            revoked: true,
          );

      await expectLater(
        session.getAccessToken(),
        throwsA(isA<GoogleSessionExpired>()),
      );
      expect((await store.read()).hasRefresh, isFalse);
      expect(await session.isLoggedIn(), isFalse);
    });

    test('a network failure keeps the refresh token for the next attempt',
        () async {
      store.tokens = OAuthTokens(
        accessToken: 'old',
        refreshToken: 'refresh',
        accessTokenExpiry: clock.subtract(const Duration(minutes: 5)),
      );
      var calls = 0;
      oauth.onRefresh = (_) async {
        calls++;
        if (calls == 1) {
          throw GoogleOAuthException('SocketException: offline');
        }
        return OAuthTokens(
          accessToken: 'new',
          accessTokenExpiry: clock.add(const Duration(hours: 1)),
        );
      };

      await expectLater(
        session.getAccessToken(),
        throwsA(isA<GoogleOAuthException>()),
      );
      expect((await store.read()).refreshToken, 'refresh');
      expect(await session.isLoggedIn(), isTrue);
      expect(await session.getAccessToken(), 'new');
    });

    test('parallel readers refresh once', () async {
      store.tokens = OAuthTokens(
        accessToken: 'old',
        refreshToken: 'refresh',
        accessTokenExpiry: clock.subtract(const Duration(minutes: 5)),
      );
      oauth.onRefresh = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return OAuthTokens(
          accessToken: 'new',
          accessTokenExpiry: clock.add(const Duration(hours: 1)),
        );
      };

      final results = await Future.wait([
        session.getAccessToken(),
        session.getAccessToken(),
      ]);

      expect(results, ['new', 'new']);
      expect(oauth.refreshes, 1);
    });

    test('logout removes the session', () async {
      store.tokens = const OAuthTokens(
        accessToken: 'access',
        refreshToken: 'refresh',
      );

      await session.logout();

      expect(await session.isLoggedIn(), isFalse);
    });
  });

  group('AppAuthGoogleOAuth', () {
    test('passes the offline-access request through and maps the tokens',
        () async {
      final appAuth = RecordingAppAuth();
      final oauth = AppAuthGoogleOAuth(appAuth);

      final tokens = await oauth.authorizeInteractive();

      expect(
          appAuth.authRequest?.additionalParameters?['access_type'], 'offline');
      expect(tokens?.accessToken, 'access');
      expect(tokens?.refreshToken, 'refresh');
      expect(tokens?.accessTokenExpiry, DateTime.utc(2026, 6, 1));
    });

    test('user cancel is not a failed token response', () async {
      final appAuth = RecordingAppAuth()..cancel = true;
      final oauth = AppAuthGoogleOAuth(appAuth);

      expect(await oauth.authorizeInteractive(), isNull);
    });

    test('refresh maps invalid_grant to a revoked session error', () async {
      final appAuth = RecordingAppAuth()..refreshRevoked = true;
      final oauth = AppAuthGoogleOAuth(appAuth);

      await expectLater(
        oauth.refresh('refresh-1'),
        throwsA(
          isA<GoogleOAuthException>()
              .having((error) => error.revoked, 'revoked', isTrue),
        ),
      );
      expect(appAuth.refreshRequest?.refreshToken, 'refresh-1');
    });
  });

  test('GoogleHealthAuth.login reports a rejected sign-in as unsuccessful',
      () async {
    final store = MemoryTokenStore();
    final oauth = FakeOAuth()
      ..onAuthorize = () async => throw GoogleOAuthException('invalid_client');
    GoogleHealthAuth.debugSetSession(
      GoogleHealthSession(store: store, oauth: oauth),
    );
    addTearDown(() => GoogleHealthAuth.debugSetSession(null));

    expect(await GoogleHealthAuth.login(), isFalse);
    expect((await store.read()).hasAccess, isFalse);
  });
}

class MemoryTokenStore implements GoogleTokenStore {
  OAuthTokens tokens = OAuthTokens.empty;

  @override
  Future<void> clear() async {
    tokens = OAuthTokens.empty;
  }

  @override
  Future<OAuthTokens> read() async => tokens;

  @override
  Future<void> write(OAuthTokens value) async {
    tokens = value;
  }
}

class FakeOAuth implements GoogleOAuthApi {
  Future<OAuthTokens?> Function()? onAuthorize;
  Future<OAuthTokens> Function(String refreshToken)? onRefresh;
  int refreshes = 0;

  @override
  Future<OAuthTokens?> authorizeInteractive() {
    final authorize = onAuthorize;
    if (authorize == null) {
      throw StateError('authorize was not expected');
    }
    return authorize();
  }

  @override
  Future<OAuthTokens> refresh(String refreshToken) {
    refreshes++;
    final refresh = onRefresh;
    if (refresh == null) {
      throw StateError('refresh was not expected');
    }
    return refresh(refreshToken);
  }
}

class RecordingAppAuth extends FlutterAppAuth {
  AuthorizationTokenRequest? authRequest;
  TokenRequest? refreshRequest;
  bool cancel = false;
  bool refreshRevoked = false;

  @override
  Future<AuthorizationTokenResponse> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  ) async {
    authRequest = request;
    if (cancel) {
      throw FlutterAppAuthUserCancelledException(
        code: 'authorize_and_exchange_code_failed',
        message: 'User cancelled flow',
        platformErrorDetails: FlutterAppAuthPlatformErrorDetails(),
      );
    }
    return AuthorizationTokenResponse(
      'access',
      'refresh',
      DateTime.utc(2026, 6, 1),
      null,
      'Bearer',
      null,
      null,
      null,
    );
  }

  @override
  Future<TokenResponse> token(TokenRequest request) async {
    refreshRequest = request;
    if (refreshRevoked) {
      throw FlutterAppAuthPlatformException(
        code: 'token_failed',
        message:
            'Failed to get token: [error: invalid_grant, description: Token has been expired or revoked.]',
        platformErrorDetails: FlutterAppAuthPlatformErrorDetails(
          error: 'invalid_grant',
          errorDescription: 'Token has been expired or revoked.',
        ),
      );
    }
    return TokenResponse(
      'new-access',
      null,
      DateTime.utc(2026, 6, 1, 1),
      null,
      'Bearer',
      null,
      null,
    );
  }
}

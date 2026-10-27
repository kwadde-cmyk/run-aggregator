import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:run_aggregator/services/data_cache.dart';
import 'package:run_aggregator/services/google_health_auth.dart';
import 'package:run_aggregator/services/google_health_service.dart';
import 'package:run_aggregator/services/google_health_session.dart';

void main() {
  late DateTime clock;
  late MemoryTokenStore store;
  late FakeOAuth oauth;

  setUp(() {
    clock = DateTime.utc(2026, 1, 1, 12);
    store = MemoryTokenStore();
    oauth = FakeOAuth();
    DataCache.clear();
    GoogleHealthAuth.debugSetSession(
      GoogleHealthSession(
        store: store,
        oauth: oauth,
        now: () => clock,
      ),
    );
  });

  tearDown(() {
    GoogleHealthAuth.debugSetSession(null);
    GoogleHealthService.httpClient = http.Client();
    DataCache.clear();
  });

  test('a still-valid access token is sent and not refreshed', () async {
    store.tokens = _live('old');
    final headers = <String?>[];
    GoogleHealthService.httpClient = MockClient((request) async {
      headers.add(request.headers['authorization']);
      return http.Response('{"dataPoints":[]}', 200);
    });

    expect(await GoogleHealthService.getExercises(forceRefresh: true), isEmpty);
    expect(headers, ['Bearer old']);
    expect(oauth.refreshes, 0);
  });

  test('an expired access token is refreshed before the API call', () async {
    store.tokens = _expired('old');
    oauth.onRefresh = (_) async => _live('new');
    final headers = <String?>[];
    GoogleHealthService.httpClient = MockClient((request) async {
      headers.add(request.headers['authorization']);
      return http.Response('{"dataPoints":[]}', 200);
    });

    expect(await GoogleHealthService.getExercises(forceRefresh: true), isEmpty);
    expect(headers, ['Bearer new']);
    expect(oauth.refreshes, 1);
    expect((await store.read()).refreshToken, 'refresh');
  });

  test('HTTP 401 refreshes once and retries with the new token', () async {
    store.tokens = _live('old');
    oauth.onRefresh = (_) async => _live('new');
    final headers = <String?>[];
    GoogleHealthService.httpClient = MockClient((request) async {
      headers.add(request.headers['authorization']);
      if (headers.length == 1) return http.Response('denied', 401);
      return http.Response('{"dataPoints":[]}', 200);
    });

    expect(await GoogleHealthService.getExercises(forceRefresh: true), isEmpty);
    expect(headers, ['Bearer old', 'Bearer new']);
    expect((await store.read()).accessToken, 'new');
    expect((await store.read()).refreshToken, 'refresh');
  });

  test('a rejected refresh token becomes a logged-out session', () async {
    store.tokens = _expired('old');
    oauth.onRefresh = (_) async => throw GoogleOAuthException(
          'invalid_grant',
          revoked: true,
        );

    await expectLater(
      GoogleHealthService.getExercises(forceRefresh: true),
      throwsA(
        predicate(
            (Object error) => error.toString().contains('UNAUTHENTICATED')),
      ),
    );
    expect((await store.read()).hasRefresh, isFalse);
    expect(await GoogleHealthAuth.isLoggedIn(), isFalse);
  });

  test('a second 401 after refresh logs the user out', () async {
    store.tokens = _live('old');
    oauth.onRefresh = (_) async => _live('new');
    GoogleHealthService.httpClient = MockClient(
      (request) async => http.Response('denied', 401),
    );

    await expectLater(
      GoogleHealthService.getExercises(forceRefresh: true),
      throwsA(
        predicate(
            (Object error) => error.toString().contains('UNAUTHENTICATED')),
      ),
    );
    expect((await store.read()).hasAccess, isFalse);
    expect((await store.read()).hasRefresh, isFalse);
  });

  test('a transient refresh failure keeps the stored session', () async {
    store.tokens = _live('old');
    oauth.onRefresh =
        (_) async => throw GoogleOAuthException('SocketException: offline');
    GoogleHealthService.httpClient = MockClient(
      (request) async => http.Response('denied', 401),
    );

    await expectLater(
      GoogleHealthService.getExercises(forceRefresh: true),
      throwsA(isA<GoogleOAuthException>()),
    );
    expect((await store.read()).refreshToken, 'refresh');
    expect(await GoogleHealthAuth.isLoggedIn(), isTrue);
    expect(
      googleHealthErrorRequiresLogin(
          GoogleOAuthException('SocketException: offline')),
      isFalse,
    );
  });
}

OAuthTokens _live(String access) {
  return OAuthTokens(
    accessToken: access,
    refreshToken: 'refresh',
    accessTokenExpiry: DateTime.utc(2026, 1, 1, 13),
  );
}

OAuthTokens _expired(String access) {
  return OAuthTokens(
    accessToken: access,
    refreshToken: 'refresh',
    accessTokenExpiry: DateTime.utc(2026, 1, 1, 11),
  );
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
  Future<OAuthTokens> Function(String refreshToken)? onRefresh;
  int refreshes = 0;

  @override
  Future<OAuthTokens?> authorizeInteractive() async => null;

  @override
  Future<OAuthTokens> refresh(String refreshToken) {
    refreshes++;
    final refresh = onRefresh;
    if (refresh == null) throw StateError('refresh was not expected');
    return refresh(refreshToken);
  }
}

// Sign-in, the saved session, and the silent token refresh — all against a
// fake server, so these run with nothing listening on port 8000.

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/api/api_client.dart';
import 'package:davao_aj_jewellers/core/api/token_store.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'package:davao_aj_jewellers/core/state/session_state.dart';

import 'support/fake_server.dart';

const _grace = {
  'id': 'USR-GRC',
  'name': 'Grace Palma',
  'role': 'cashier',
  'home_branch': 'kidapawan',
  'contact_number': '0917 000 0000',
  'active': true,
};

({SessionState session, FakeServer server, MemoryTokenStore store}) _wire() {
  final server = FakeServer();
  final store = MemoryTokenStore();
  final api = ApiClient(httpClient: server, baseUrl: FakeServer.base);
  return (session: SessionState(api: api, store: store), server: server, store: store);
}

void main() {
  group('signing in with a PIN', () {
    test('the staff list comes from the server, without a token', () async {
      final w = _wire();
      w.server.on('GET', 'auth/staff', body: [
        _grace,
        {'id': 'USR-ADM', 'name': 'Ada Reyes', 'role': 'admin', 'home_branch': null, 'active': true},
      ]);

      final staff = await w.session.staff();

      expect(staff.map((u) => u.name), ['Grace Palma', 'Ada Reyes']);
      expect(staff.first.role, AppUserRole.cashier);
      expect(staff.first.homeBranch, BranchId.kidapawan);
      expect(staff.last.homeBranch, isNull);
      expect(w.server.callsTo('GET', 'auth/staff').single.headers.containsKey('Authorization'), isFalse);
    });

    test('the right PIN signs in and the session is saved for next launch', () async {
      final w = _wire();
      w.server.on('POST', 'auth/login', body: {
        'access': 'access-1',
        'refresh': 'refresh-1',
        'user': _grace,
      });

      await w.session.signIn(userId: 'USR-GRC', pin: '1234');

      expect(w.session.isSignedIn, isTrue);
      expect(w.session.user!.name, 'Grace Palma');
      final sent = w.server.callsTo('POST', 'auth/login').single;
      expect(sent.body, contains('"pin":"1234"'));
      expect(sent.body, isNot(contains('actor')), reason: 'the token says who it is');

      // What a restart would read back.
      final saved = await w.store.read();
      expect(saved!['access'], 'access-1');
      expect((saved['user'] as Map)['id'], 'USR-GRC');
    });

    test('a saved session is restored without asking for the PIN again', () async {
      final w = _wire();
      await w.store.write({
        'access': 'access-1',
        'refresh': 'refresh-1',
        'user': _grace,
      });

      expect(w.session.isRestoring, isTrue);
      final signedIn = await w.session.restore();

      expect(signedIn, isTrue);
      expect(w.session.isRestoring, isFalse);
      expect(w.session.user!.id, 'USR-GRC');
    });

    test('a wrong PIN is refused and nobody is signed in', () async {
      final w = _wire();
      w.server.on('POST', 'auth/login', status: 401, body: {
        'error': {'code': 'bad_pin', 'message': 'That PIN is not right.'}
      });

      await expectLater(
        w.session.signIn(userId: 'USR-GRC', pin: '9999'),
        throwsA(isA<ApiUnauthorized>()),
      );
      expect(w.session.isSignedIn, isFalse);
      expect(await w.store.read(), isNull);
    });

    test('signing out clears the saved session', () async {
      final w = _wire();
      w.server.on('POST', 'auth/login', body: {'access': 'a', 'refresh': 'r', 'user': _grace});
      await w.session.signIn(userId: 'USR-GRC', pin: '1234');

      await w.session.signOut();

      expect(w.session.isSignedIn, isFalse);
      expect(await w.store.read(), isNull);
    });
  });

  group('token refresh', () {
    test('a 401 mid-request is refreshed and retried, so nobody sees an error', () async {
      final w = _wire();
      w.server.on('POST', 'auth/login', body: {'access': 'stale', 'refresh': 'refresh-1', 'user': _grace});
      w.server.on('POST', 'auth/refresh', body: {'access': 'fresh', 'refresh': 'refresh-2'});
      // Expired the first time, fine once the new token arrives.
      w.server.on('GET', 'sync/snapshot', handler: (_) {
        return const FakeReply(401, {
          'error': {'code': 'token_expired', 'message': 'expired'}
        });
      });

      await w.session.signIn(userId: 'USR-GRC', pin: '1234');
      w.server.on('GET', 'sync/snapshot', body: {'cursor': 7});
      // The first-registered route wins, so swap in one that expires once.
      var served = 0;
      w.server.reset(['GET sync/snapshot']);
      w.server.on('GET', 'sync/snapshot', handler: (_) {
        served++;
        return served == 1
            ? const FakeReply(401, {
                'error': {'code': 'token_expired', 'message': 'expired'}
              })
            : const FakeReply(200, {'cursor': 7});
      });

      final response = await w.session.api.get('sync/snapshot');

      expect(response.map['cursor'], 7);
      expect(served, 2, reason: 'one retry, after the refresh');
      expect(w.server.countOf('POST', 'auth/refresh'), 1);
      final calls = w.server.callsTo('GET', 'sync/snapshot');
      expect(calls.first.headers['Authorization'], 'Bearer stale');
      expect(calls.last.headers['Authorization'], 'Bearer fresh');
      // The replacement refresh token is the one kept for next time.
      expect((await w.store.read())!['refresh'], 'refresh-2');
    });

    test('a refresh token the server rejects ends the session instead of looping', () async {
      final w = _wire();
      w.server.on('POST', 'auth/login', body: {'access': 'a', 'refresh': 'r', 'user': _grace});
      await w.session.signIn(userId: 'USR-GRC', pin: '1234');
      w.server.on('POST', 'auth/refresh', status: 401, body: {
        'error': {'code': 'token_invalid', 'message': 'Sign in again.'}
      });
      w.server.on('GET', 'sync/snapshot', status: 401, body: {
        'error': {'code': 'token_expired', 'message': 'expired'}
      });

      await expectLater(
        w.session.api.get('sync/snapshot'),
        throwsA(isA<ApiUnauthorized>()),
      );
      // One refresh attempt, not a loop.
      expect(w.server.countOf('POST', 'auth/refresh'), 1);
      expect(w.server.countOf('GET', 'sync/snapshot'), 1);
    });

    test('with nothing signed in there is nothing to refresh', () async {
      final w = _wire();
      expect(await w.session.refreshTokens(), isFalse);
      expect(w.server.requests, isEmpty);
    });
  });

  group('changing a PIN', () {
    test('new tokens are adopted, so the old ones stop working', () async {
      final w = _wire();
      w.server.on('POST', 'auth/login', body: {'access': 'old', 'refresh': 'old-r', 'user': _grace});
      await w.session.signIn(userId: 'USR-GRC', pin: '1234');
      w.server.on('POST', 'me/pin', body: {'access': 'new', 'refresh': 'new-r', 'user': _grace});

      await w.session.changePin(currentPin: '1234', newPin: '4321');

      final saved = await w.store.read();
      expect(saved!['access'], 'new');
      expect(saved['refresh'], 'new-r');
      final sent = w.server.callsTo('POST', 'me/pin').single;
      expect(sent.body, contains('"current_pin":"1234"'));
      expect(sent.body, contains('"new_pin":"4321"'));
    });

    test('the server refusing a weak PIN comes back as a refusal to show', () async {
      final w = _wire();
      w.server.on('POST', 'auth/login', body: {'access': 'a', 'refresh': 'r', 'user': _grace});
      await w.session.signIn(userId: 'USR-GRC', pin: '1234');
      w.server.on('POST', 'me/pin', status: 422, body: {
        'error': {'code': 'weak_pin', 'message': 'A PIN is 4 to 6 digits.'}
      });

      await expectLater(
        w.session.changePin(currentPin: '1234', newPin: '1'),
        throwsA(isA<ApiRefusal>().having((e) => e.message, 'message', 'A PIN is 4 to 6 digits.')),
      );
    });
  });
}

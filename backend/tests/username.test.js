import test, { after, before, describe } from 'node:test';
import assert from 'node:assert/strict';
// Imported first on purpose: it configures process.env before any src module loads.
import './harness.js';
import { validateUsername, suggestionsFor } from '../src/username.js';
import {
  api,
  closeDatabase,
  createUnclaimedUser,
  createUser,
  request,
  resetDatabase,
  sql,
  startTestServer,
  uniqueEmail,
} from './harness.js';

let server;
let base;

before(async () => {
  await resetDatabase();
  server = await startTestServer();
  base = server.baseUrl;
});

after(async () => {
  await server?.close();
  await closeDatabase();
});

describe('username rules (unit)', () => {
  const valid = ['abc', 'jane', 'jane.doe', 'jane_doe', 'a1b2c3', 'abcdefghijklmnopqrst', 'hey.you_2'];
  const invalid = [
    ['ab', 'too_short'],
    ['x'.repeat(21), 'too_long'],
    ['1abc', 'must_start_with_letter'],
    ['_abc', 'must_start_with_letter'],
    ['.abc', 'must_start_with_letter'],
    ['ab..c', 'consecutive_periods'],
    ['abc.', 'trailing_period'],
    ['ab-c', 'invalid_characters'],
    ['ab c', 'invalid_characters'],
    ['adé', 'invalid_characters'],
    ['admin', 'reserved'],
    ['administrator', 'reserved'],
    ['support', 'reserved'],
    ['moderator', 'reserved'],
    ['official', 'reserved'],
    ['security', 'reserved'],
    ['api', 'reserved'],
    ['null', 'reserved'],
    ['undefined', 'reserved'],
    ['adm1n', 'reserved'],
    ['ad.min', 'reserved'],
    ['sh1t', 'offensive'],
    ['f.u.c.k', 'offensive'],
    ['n4z1', 'offensive'],
  ];

  test('accepts valid usernames', () => {
    for (const name of valid) {
      assert.equal(validateUsername(name).ok, true, `${name} should be valid`);
    }
  });

  test('rejects invalid usernames with a specific reason', () => {
    for (const [name, code] of invalid) {
      const result = validateUsername(name);
      assert.equal(result.ok, false, `${name} should be invalid`);
      assert.equal(result.code, code, `${name} should fail with ${code}`);
    }
  });

  test('normalizes upper case input', () => {
    const result = validateUsername('  JaneDoe ');
    assert.equal(result.ok, true);
    assert.equal(result.username, 'janedoe');
  });

  test('suggestions are themselves valid usernames', () => {
    const suggestions = suggestionsFor('jane');
    assert.ok(suggestions.length >= 2);
    for (const suggestion of suggestions) {
      assert.equal(validateUsername(suggestion).ok, true, suggestion);
      assert.notEqual(suggestion, 'jane');
    }
  });
});

describe('username allocation over HTTP', () => {
  test('exposes the rules endpoint with the profile URL format', async () => {
    const res = await request(base, '/v1/auth/username-rules');
    assert.equal(res.status, 200);
    assert.equal(res.body.minLength, 3);
    assert.equal(res.body.maxLength, 20);
    assert.equal(res.body.changeCooldownDays, 30);
    assert.equal(res.body.reuseCooldownDays, 90);
    assert.equal(res.body.profileUrlFormat, 'https://worldfriends.app/@username');
  });

  test('live availability says available / taken / invalid', async () => {
    const free = await request(base, '/v1/username/available?username=freename');
    assert.equal(free.body.available, true);

    await createUser(base, { username: 'takenone' });
    const taken = await request(base, '/v1/username/available?username=takenone');
    assert.equal(taken.body.available, false);
    assert.equal(taken.body.reason, 'taken');
    assert.ok(taken.body.suggestions.length > 0, 'expect suggestions for a taken name');

    const invalid = await request(base, '/v1/username/available?username=admin');
    assert.equal(invalid.body.available, false);
    assert.equal(invalid.body.reason, 'reserved');
  });

  test('claiming stores the username and returns the profile URL', async () => {
    const user = await createUser(base, { username: 'janedoe' });
    assert.equal(user.user.username, 'janedoe');
    const me = await api(base, user.token)('/v1/auth/me');
    assert.equal(me.body.user.profileUrl, 'https://worldfriends.app/@janedoe');
    assert.equal(me.body.user.needsUsername, false);
  });

  test('a second user cannot take the same username', async () => {
    await createUser(base, { username: 'duplicate1' });
    const other = await createUnclaimedUser(base);
    const res = await api(base, other.token)('/v1/username/claim', {
      method: 'POST',
      body: { username: 'duplicate1' },
    });
    assert.equal(res.status, 409);
    assert.equal(res.body.error.code, 'username_taken');
    assert.ok(res.body.error.details.suggestions.length > 0);
  });

  test('concurrent claims for one username: exactly one winner', async () => {
    const users = await Promise.all(
      Array.from({ length: 6 }, () => createUnclaimedUser(base)),
    );
    const results = await Promise.all(
      users.map((user) =>
        api(base, user.token)('/v1/username/claim', {
          method: 'POST',
          body: { username: 'racename' },
        }),
      ),
    );
    const winners = results.filter((r) => r.status === 201);
    const losers = results.filter((r) => r.status === 409);
    assert.equal(winners.length, 1, `expected exactly one winner, got ${JSON.stringify(results.map((r) => r.status))}`);
    assert.equal(losers.length, 5);
    const { rows } = await sql('select count(*)::int as n from users where username = $1', ['racename']);
    assert.equal(rows[0].n, 1);
  });

  test('username changes are limited to once every 30 days', async () => {
    const user = await createUser(base, { username: 'firstname' });
    const immediate = await api(base, user.token)('/v1/username/change', {
      method: 'POST',
      body: { username: 'secondname', confirm: true },
    });
    assert.equal(immediate.status, 429);
    assert.equal(immediate.body.error.code, 'username_change_cooldown');
    assert.ok(immediate.body.error.details.nextChangeAt);

    // Pretend the claim was 31 days ago.
    await sql('update users set username_changed_at = now() - interval \'31 days\' where id = $1', [user.id]);
    const changed = await api(base, user.token)('/v1/username/change', {
      method: 'POST',
      body: { username: 'secondname', confirm: true },
    });
    assert.equal(changed.status, 200);
    assert.equal(changed.body.username, 'secondname');
    assert.equal(changed.body.previous, 'firstname');

    const history = await sql('select username from username_history where user_id = $1', [user.id]);
    assert.deepEqual(history.rows.map((r) => r.username), ['firstname']);
  });

  test('a released username cannot be reused for 90 days', async () => {
    const owner = await createUser(base, { username: 'oldschool' });
    await sql('update users set username_changed_at = now() - interval \'31 days\' where id = $1', [owner.id]);
    await api(base, owner.token)('/v1/username/change', {
      method: 'POST',
      body: { username: 'newschool', confirm: true },
    });

    const newcomer = await createUnclaimedUser(base);
    const blocked = await api(base, newcomer.token)('/v1/username/claim', {
      method: 'POST',
      body: { username: 'oldschool' },
    });
    assert.equal(blocked.status, 409);
    assert.equal(blocked.body.error.code, 'username_recently_released');

    const availability = await request(base, '/v1/username/available?username=oldschool');
    assert.equal(availability.body.available, false);
    assert.equal(availability.body.reason, 'recently_released');

    // After the cool-down the name is free again.
    await sql('update username_history set released_at = now() - interval \'91 days\' where username = $1', [
      'oldschool',
    ]);
    const later = await api(base, newcomer.token)('/v1/username/claim', {
      method: 'POST',
      body: { username: 'oldschool' },
    });
    assert.equal(later.status, 201, JSON.stringify(later.body));
  });

  test('the original owner can reclaim a name they released', async () => {
    const owner = await createUser(base, { username: 'comeback' });
    await sql('update users set username_changed_at = now() - interval \'31 days\' where id = $1', [owner.id]);
    await api(base, owner.token)('/v1/username/change', {
      method: 'POST',
      body: { username: 'movingon', confirm: true },
    });
    await sql('update users set username_changed_at = now() - interval \'31 days\' where id = $1', [owner.id]);
    const back = await api(base, owner.token)('/v1/username/change', {
      method: 'POST',
      body: { username: 'comeback', confirm: true },
    });
    assert.equal(back.status, 200, JSON.stringify(back.body));
  });

  test('change requires explicit confirmation', async () => {
    const user = await createUser(base, { username: 'confirmtest' });
    await sql('update users set username_changed_at = now() - interval \'31 days\' where id = $1', [user.id]);
    const res = await api(base, user.token)('/v1/username/change', {
      method: 'POST',
      body: { username: 'anothername' },
    });
    assert.equal(res.status, 400);
  });

  test('an unverified user cannot claim a username', async () => {
    const email = uniqueEmail('noverify');
    const reg = await request(base, '/v1/auth/register', {
      method: 'POST',
      body: { email, password: 'Passw0rd!23', inviteCode: 'FRIENDS2026' },
    });
    const login = await request(base, '/v1/auth/login', {
      method: 'POST',
      body: { email, password: 'Passw0rd!23' },
    });
    assert.equal(login.status, 403);
    // Claim requires auth, which requires a verified email in this flow.
    const claim = await request(base, '/v1/username/claim', {
      method: 'POST',
      body: { username: 'sneaky' },
      token: 'not-a-token',
    });
    assert.equal(claim.status, 401);
    assert.equal(reg.status, 201);
  });
});

describe('search', () => {
  test('finds users by exact, partial username and display name', async () => {
    const alice = await createUser(base, { username: 'alicewonder', displayName: 'Alice Wonder' });
    await createUser(base, { username: 'alicefan', displayName: 'Someone Else' });
    const seeker = await createUser(base, { username: 'seekerq' });

    const exact = await api(base, seeker.token)('/v1/users/search?q=alicewonder');
    assert.equal(exact.status, 200);
    assert.equal(exact.body.results[0].username, 'alicewonder');
    assert.equal(exact.body.results[0].matchType, 'exact');

    const partial = await api(base, seeker.token)('/v1/users/search?q=alice');
    const names = partial.body.results.map((r) => r.username);
    assert.ok(names.includes('alicewonder'));
    assert.ok(names.includes('alicefan'));

    const byDisplay = await api(base, seeker.token)('/v1/users/search?q=Wonder');
    assert.ok(byDisplay.body.results.some((r) => r.username === 'alicewonder'));

    const withAt = await api(base, seeker.token)('/v1/users/search?q=@alicewonder');
    assert.equal(withAt.body.results[0].username, 'alicewonder');

    assert.equal(partial.body.results.some((r) => r.id === seeker.id), false, 'search excludes self');
  });

  test('paginates results', async () => {
    const seeker = await createUser(base);
    for (let i = 0; i < 6; i += 1) {
      await createUser(base, { username: `pager${i}ab` });
    }
    const first = await api(base, seeker.token)('/v1/users/search?q=pager&limit=2');
    assert.equal(first.body.results.length, 2);
    assert.ok(first.body.nextCursor);
    const second = await api(base, seeker.token)(
      `/v1/users/search?q=pager&limit=2&cursor=${encodeURIComponent(first.body.nextCursor)}`,
    );
    const firstIds = first.body.results.map((r) => r.id);
    const secondIds = second.body.results.map((r) => r.id);
    assert.equal(secondIds.some((id) => firstIds.includes(id)), false);
  });

  test('profile lookup by username works and 404s for unknown', async () => {
    const target = await createUser(base, { username: 'profileuser' });
    const viewer = await createUser(base);
    const ok = await api(base, viewer.token)(`/v1/users/${target.username}`);
    assert.equal(ok.status, 200);
    assert.equal(ok.body.user.username, 'profileuser');
    assert.equal(ok.body.user.profileUrl, 'https://worldfriends.app/@profileuser');

    const missing = await api(base, viewer.token)('/v1/users/nosuchusername');
    assert.equal(missing.status, 404);
  });
});

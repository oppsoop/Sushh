import test, { after, before, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import './harness.js';
import { closeDatabase, resetDatabase } from './harness.js';

let verifyGoogleIdToken;
let signMediaUrl;
let verifyMediaSignature;
let encodeCursor;
let decodeCursor;
let encodeValues;
let decodeValues;
let validateUsername;

function b64url(buf) {
  return Buffer.from(buf).toString('base64url');
}

function makeKeyPair(kid) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = publicKey.export({ format: 'jwk' });
  return { privateKey, jwk: { ...jwk, kid, alg: 'RS256', use: 'sig' } };
}

function signIdToken(privateKey, kid, payload) {
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT', kid }));
  const body = b64url(JSON.stringify(payload));
  const signature = crypto.createSign('RSA-SHA256').update(`${header}.${body}`).sign(privateKey);
  return `${header}.${body}.${b64url(signature)}`;
}

before(async () => {
  process.env.GOOGLE_CLIENT_IDS = 'test-client-id.apps.googleusercontent.com,android-client-id';
  await resetDatabase();
  const auth = await import('../src/auth.js');
  verifyGoogleIdToken = auth.verifyGoogleIdToken;
  const storage = await import('../src/storage.js');
  signMediaUrl = storage.signedMediaUrl;
  verifyMediaSignature = storage.verifyMediaSignature;
  const util = await import('../src/util.js');
  encodeCursor = util.encodeCursor;
  decodeCursor = util.decodeCursor;
  encodeValues = util.encodeValues;
  decodeValues = util.decodeValues;
  const username = await import('../src/username.js');
  validateUsername = username.validateUsername;
});

after(async () => {
  await closeDatabase();
});

describe('google id token verification', () => {
  const { privateKey, jwk } = makeKeyPair('kid-1');
  const keysProvider = async () => [jwk];
  const now = Math.floor(Date.now() / 1000);

  test('accepts a valid Google ID token', async () => {
    const token = signIdToken(privateKey, 'kid-1', {
      iss: 'https://accounts.google.com',
      aud: 'test-client-id.apps.googleusercontent.com',
      sub: 'google-user-1',
      email: 'Someone@Example.com',
      email_verified: true,
      name: 'Someone',
      iat: now,
      exp: now + 600,
    });
    const result = await verifyGoogleIdToken(token, { keysProvider });
    assert.equal(result.sub, 'google-user-1');
    assert.equal(result.email, 'someone@example.com');
    assert.equal(result.emailVerified, true);
  });

  test('rejects a token signed by a different key', async () => {
    const other = makeKeyPair('kid-1');
    const token = signIdToken(other.privateKey, 'kid-1', {
      iss: 'accounts.google.com',
      aud: 'test-client-id.apps.googleusercontent.com',
      sub: 'x',
      email: 'x@example.com',
      exp: now + 600,
    });
    await assert.rejects(() => verifyGoogleIdToken(token, { keysProvider }), /signature invalid/);
  });

  test('rejects the wrong audience', async () => {
    const token = signIdToken(privateKey, 'kid-1', {
      iss: 'accounts.google.com',
      aud: 'someone-elses-app',
      sub: 'x',
      email: 'x@example.com',
      exp: now + 600,
    });
    await assert.rejects(() => verifyGoogleIdToken(token, { keysProvider }), /not issued for this app/);
  });

  test('rejects expired tokens and wrong issuers', async () => {
    const expired = signIdToken(privateKey, 'kid-1', {
      iss: 'accounts.google.com',
      aud: 'test-client-id.apps.googleusercontent.com',
      sub: 'x',
      email: 'x@example.com',
      exp: now - 10,
    });
    await assert.rejects(() => verifyGoogleIdToken(expired, { keysProvider }), /expired/);

    const wrongIssuer = signIdToken(privateKey, 'kid-1', {
      iss: 'evil.example.com',
      aud: 'test-client-id.apps.googleusercontent.com',
      sub: 'x',
      email: 'x@example.com',
      exp: now + 600,
    });
    await assert.rejects(() => verifyGoogleIdToken(wrongIssuer, { keysProvider }), /issuer/);
  });

  test('rejects malformed tokens', async () => {
    await assert.rejects(() => verifyGoogleIdToken('not-a-jwt', { keysProvider }), /Malformed/);
  });
});

describe('signed media urls', () => {
  const id = '11111111-1111-1111-1111-111111111111';

  function parse(url) {
    const query = new URLSearchParams(url.split('?')[1]);
    return { exp: query.get('exp'), sig: query.get('sig') };
  }

  test('a generated signature verifies', () => {
    const { exp, sig } = parse(signMediaUrl(id, { ttl: 600 }));
    assert.equal(verifyMediaSignature(id, 'content', exp, sig), true);
  });

  test('expired signatures fail', () => {
    const { exp, sig } = parse(signMediaUrl(id, { ttl: -10 }));
    assert.equal(verifyMediaSignature(id, 'content', exp, sig), false);
  });

  test('signatures are bound to the media id and variant', () => {
    const { exp, sig } = parse(signMediaUrl(id, { ttl: 600 }));
    assert.equal(verifyMediaSignature('22222222-2222-2222-2222-222222222222', 'content', exp, sig), false);
    assert.equal(verifyMediaSignature(id, 'thumb', exp, sig), false);
  });
});

describe('cursor helpers', () => {
  test('round trips date cursors', () => {
    const date = new Date('2026-01-02T03:04:05.678Z');
    const cursor = encodeCursor(date, 'abc');
    const decoded = decodeCursor(cursor);
    assert.equal(decoded.createdAt.toISOString(), date.toISOString());
    assert.equal(decoded.id, 'abc');
  });

  test('rejects corrupt cursors instead of throwing', () => {
    assert.equal(decodeCursor('!!!not-base64!!!'), null);
    assert.equal(decodeCursor(Buffer.from('{"a":1}').toString('base64url')), null);
    assert.equal(decodeCursor(null), null);
  });

  test('round trips value cursors', () => {
    const cursor = encodeValues([1, 'alice', 'uuid']);
    assert.deepEqual(decodeValues(cursor, 3), [1, 'alice', 'uuid']);
    assert.equal(decodeValues(cursor, 2), null);
    assert.equal(decodeValues('garbage', 3), null);
  });
});

describe('username rule edges', () => {
  test('rejects whitespace and unicode tricks', () => {
    assert.equal(validateUsername('   ').ok, false);
    assert.equal(validateUsername('abc ').username, 'abc');
    assert.equal(validateUsername('аdmin').ok, false); // Cyrillic "а"
  });

  test('allows periods and underscores in the middle', () => {
    assert.equal(validateUsername('a.b_c.1').ok, true);
    assert.equal(validateUsername('a..b').ok, false);
  });
});

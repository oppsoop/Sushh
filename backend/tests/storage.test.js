import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';

// Fake S3-compatible endpoint verifies streamed size/content type and failure
// propagation without requiring third-party credentials or internet access.
test('S3 uploads stream bytes and failed deletion remains retryable', async () => {
  const seen = [];
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    seen.push({ method: req.method, url: req.url, headers: req.headers, body: Buffer.concat(chunks) });
    res.writeHead(req.method === 'DELETE' ? 403 : 200).end();
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const endpoint = `http://127.0.0.1:${server.address().port}`;
    const source = `
      import { Readable } from 'node:stream';
      import { putStream, deleteObject } from './src/storage.js';
      await putStream('folder/test.txt', Readable.from([Buffer.from('hello'), Buffer.from('world')]), {size: 10, contentType: 'text/plain'});
      let failed = false;
      try { await deleteObject('folder/test.txt'); } catch { failed = true; }
      if (!failed) throw new Error('Failed delete was swallowed');
    `;
    const child = spawn(process.execPath, ['--input-type=module', '-e', source], {
      cwd: process.cwd(), env: { ...process.env, STORAGE: 's3', S3_ENDPOINT: endpoint,
        S3_BUCKET: 'test-bucket', S3_REGION: 'auto', S3_ACCESS_KEY_ID: 'test', S3_SECRET_ACCESS_KEY: 'test' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = ''; child.stderr.on('data', (chunk) => { stderr += chunk; });
    const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); });
    assert.equal(code, 0, stderr);
    assert.equal(seen.length, 2);
    assert.equal(seen[0].method, 'PUT');
    assert.ok(seen[0].url.startsWith('/test-bucket/folder/test.txt?'));
    assert.equal(seen[0].headers['content-length'], '10');
    assert.equal(seen[0].headers['content-type'], 'text/plain');
    assert.equal(seen[0].body.toString(), 'helloworld');
    assert.equal(seen[1].method, 'DELETE');
  } finally { await new Promise((resolve) => server.close(resolve)); }
});

'use strict';

const net = require('net');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createController } = require('../server.js');

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'yeelight-test-'));
}

/** HTTP request to the controller. Returns { status, body } (body parsed as JSON when possible). */
function request(port, method, urlPath, { body, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const h = Object.assign({ Host: `127.0.0.1:${port}` }, headers);
    if (payload !== null) {
      if (!Object.keys(h).some((k) => k.toLowerCase() === 'content-type')) h['Content-Type'] = 'application/json';
      h['Content-Length'] = Buffer.byteLength(payload);
    }
    const req = http.request({ host: '127.0.0.1', port, method, path: urlPath, headers: h, agent: false }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let parsed = text;
        try { parsed = JSON.parse(text); } catch (e) {}
        resolve({ status: res.statusCode, body: parsed, headers: res.headers });
      });
    });
    req.on('error', reject);
    if (payload !== null) req.write(payload);
    req.end();
  });
}

async function waitFor(fn, { timeout = 3000, interval = 10, message = 'condition' } = {}) {
  const start = Date.now();
  let last;
  for (;;) {
    last = await fn();
    if (last) return last;
    if (Date.now() - start > timeout) throw new Error(`Timed out after ${timeout} ms waiting for ${message}`);
    await new Promise((r) => setTimeout(r, interval));
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Starts a controller on a pre-picked free port (so the Host allowlist matches)
 * with config files in a fresh temp dir. Returns helpers bound to it.
 */
async function startController(opts = {}) {
  const dir = tmpDir();
  const port = await freePort();
  const ctrl = createController(Object.assign({
    port,
    configPath: path.join(dir, 'config.json'),
    legacyConfigPath: path.join(dir, 'legacy.json'),
    reconnectBaseMs: 50,
    reconnectMaxMs: 200,
    scanNetwork: async () => [],
    log: () => {}
  }, opts));
  const actual = await ctrl.listen();
  const api = {
    ctrl,
    port: actual,
    dir,
    configPath: opts.configPath || path.join(dir, 'config.json'),
    req: (method, p, o) => request(actual, method, p, o),
    status: async () => (await request(actual, 'GET', '/api/status')).body,
    connect: (bulbPort) => request(actual, 'POST', '/api/connect', { body: { host: '127.0.0.1', port: bulbPort } }),
    command: (method, params) => request(actual, 'POST', '/api/command', { body: { method, params } }),
    async close() {
      await ctrl.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  };
  return api;
}

module.exports = { freePort, tmpDir, request, waitFor, sleep, startController };

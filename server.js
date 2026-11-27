#!/usr/bin/env node

/**
 * Yeelight QuickControl — standalone web controller.
 *
 * The macOS app talks to the bulb natively (see YeelightController.swift) and
 * does not need Node.js. This zero-dependency script exposes the same API and
 * dashboard in a regular browser for users who prefer that, or for other
 * platforms.
 */

const http = require('http');
const net = require('net');
const dgram = require('dgram');
const os = require('os');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const DEFAULT_PORT = 7655;
const BULB_PORT = 55443;
const MAX_BODY_BYTES = 16 * 1024;
const PROP_KEYS = ['power', 'bright', 'ct', 'rgb', 'hue', 'sat', 'color_mode'];
const ALLOWED_LANGUAGES = new Set(['en', 'tr', 'fr', 'pt', 'zh', 'de', 'it']);
const ALLOWED_COMMANDS = new Set(['set_power', 'set_bright', 'set_hsv', 'set_ct_abx', 'set_scene']);
// A queued scene supersedes these (it sets power, brightness and colour at once).
const SUPERSEDED_BY_SCENE = ['set_bright', 'set_ct_abx', 'set_hsv', 'set_power'];
const MAX_FAVORITES = 12;
const MAX_FAVORITE_NAME = 24;
const IGNORED_INTERFACES = /^(utun|bridge|awdl|llw|vmnet|vboxnet|docker|veth|ipsec|ppp)/;

// Yeelight bulbs allow ~60 commands per minute per device and drop clients
// that exceed it. Stay comfortably below that.
const COMMAND_QUOTA_PER_MINUTE = 50;
const COMMAND_BURST = 15;
const POLL_INTERVAL_MS = 10000;
const POLL_TOKEN_RESERVE = 5;

// --- Validation (pure, exported for tests) ---

/** Numbers and numeric strings become numbers; anything else (bools, null, '') becomes NaN. */
const num = (v) => (typeof v === 'number' || (typeof v === 'string' && v.trim() !== '')) ? Number(v) : NaN;
const inRange = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;

/** `set_scene` params: ["ct", kelvin, bright] or ["hsv", hue, sat, bright]. No transition. */
function validateScene(params) {
  if (params[0] === 'ct' && params.length === 3) {
    const k = num(params[1]);
    const b = num(params[2]);
    if (inRange(k, 1700, 6500) && inRange(b, 1, 100)) return ['ct', k, b];
  } else if (params[0] === 'hsv' && params.length === 4) {
    const h = num(params[1]);
    const s = num(params[2]);
    const b = num(params[3]);
    if (inRange(h, 0, 359) && inRange(s, 0, 100) && inRange(b, 1, 100)) return ['hsv', h, s, b];
  }
  return null;
}

/**
 * Validates a full favorites list. Returns the sanitized list (unknown and
 * off-mode fields stripped, names trimmed, numbers coerced) or null.
 */
function sanitizeFavorites(list) {
  if (!Array.isArray(list) || list.length > MAX_FAVORITES) return null;
  const out = [];
  for (const item of list) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) return null;
    if (typeof item.name !== 'string') return null;
    const name = item.name.trim();
    const nameLength = [...name].length; // Unicode scalars, same as Swift's unicodeScalars.count
    if (nameLength < 1 || nameLength > MAX_FAVORITE_NAME) return null;
    const bright = num(item.bright);
    if (!inRange(bright, 1, 100)) return null;
    if (item.mode === 'ct') {
      const ct = num(item.ct);
      if (!inRange(ct, 1700, 6500)) return null;
      out.push({ name, mode: 'ct', bright, ct });
    } else if (item.mode === 'hsv') {
      const hue = num(item.hue);
      const sat = num(item.sat);
      if (!inRange(hue, 0, 359) || !inRange(sat, 0, 100)) return null;
      out.push({ name, mode: 'hsv', bright, hue, sat });
    } else {
      return null;
    }
  }
  return out;
}

function sanitizeTransition(effect, duration) {
  const out = [];
  if (effect === undefined) return out;
  if (effect !== 'smooth' && effect !== 'sudden') return null;
  out.push(effect);
  if (duration === undefined) return out;
  const d = Number(duration);
  if (!Number.isInteger(d) || d < 30 || d > 10000) return null;
  out.push(d);
  return out;
}

/** Returns { params } on success or { error } on failure. */
function validateCommand(method, params) {
  if (typeof method !== 'string' || !ALLOWED_COMMANDS.has(method) || !Array.isArray(params)) {
    return { error: 'unsupported method or invalid params' };
  }
  if (method === 'set_scene') {
    const scene = validateScene(params);
    return scene ? { params: scene } : { error: 'invalid scene' };
  }

  let head;
  let rest;
  switch (method) {
    case 'set_power':
      if (params[0] !== 'on' && params[0] !== 'off') return { error: 'power must be on or off' };
      head = [params[0]];
      rest = params.slice(1);
      break;
    case 'set_bright': {
      const v = num(params[0]);
      if (!inRange(v, 1, 100)) return { error: 'brightness must be between 1 and 100' };
      head = [v];
      rest = params.slice(1);
      break;
    }
    case 'set_hsv': {
      const h = num(params[0]);
      const s = num(params[1]);
      if (!inRange(h, 0, 359) || !inRange(s, 0, 100)) return { error: 'hue or saturation is out of range' };
      head = [h, s];
      rest = params.slice(2);
      break;
    }
    case 'set_ct_abx': {
      const k = num(params[0]);
      if (!inRange(k, 1700, 6500)) return { error: 'color temperature must be between 1700 and 6500' };
      head = [k];
      rest = params.slice(1);
      break;
    }
  }
  if (rest.length > 2) return { error: 'too many params' };
  const transition = sanitizeTransition(rest[0], rest[1]);
  if (transition === null) return { error: 'invalid transition (effect must be smooth/sudden, duration 30-10000 ms)' };
  return { params: head.concat(transition) };
}

/** Hosts to probe for a given IPv4 interface: its real range when /24 or smaller, otherwise its /24. */
function hostsForInterface(address, netmask) {
  const toInt = (ip) => ip.split('.').reduce((acc, o) => ((acc << 8) | Number(o)) >>> 0, 0);
  const toIp = (n) => [24, 16, 8, 0].map((s) => (n >>> s) & 255).join('.');
  const addr = toInt(address);
  let mask = toInt(netmask || '255.255.255.0');
  if (mask < toInt('255.255.255.0')) mask = toInt('255.255.255.0');
  const network = (addr & mask) >>> 0;
  const broadcast = (network | (~mask >>> 0)) >>> 0;
  const hosts = [];
  for (let n = network + 1; n < broadcast; n++) {
    if (n !== addr) hosts.push(toIp(n));
  }
  return hosts;
}

// --- Controller factory ---

function createController(options = {}) {
  const port = options.port ?? DEFAULT_PORT;
  const configPath = options.configPath || path.join(os.homedir(), '.yeelight-quickcontrol.json');
  const legacyConfigPath = options.legacyConfigPath || path.join(os.homedir(), '.smart-lights.json');
  const reconnectBaseMs = options.reconnectBaseMs ?? 2000;
  const reconnectMaxMs = options.reconnectMaxMs ?? 60000;
  const scanNetworkImpl = options.scanNetwork || scanNetwork;
  const log = options.log || ((...args) => console.log(...args));

  const allowedOrigins = new Set([`http://127.0.0.1:${port}`, `http://localhost:${port}`]);
  const allowedHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);

  let device = { host: null, port: BULB_PORT };
  let socket = null;
  let connected = false;
  let manualDisconnect = false;
  let reconnectTimer = null;
  let reconnectAttempts = 0;
  let closed = false;
  let nextId = 1;
  const pendingPropIds = new Set();
  let dataBuffer = '';
  const props = {
    power: 'off', bright: '100', ct: '4000', rgb: '16777215', hue: '0', sat: '100', color_mode: '2'
  };

  // --- Configuration ---
  function loadConfig() {
    for (const p of [configPath, legacyConfigPath]) {
      try {
        if (fs.existsSync(p)) {
          const parsed = JSON.parse(fs.readFileSync(p, 'utf8'));
          if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed;
        }
      } catch (e) {
        log(`[Config] Ignoring unreadable config ${p}: ${e.message}`);
      }
    }
    return null;
  }

  /** Merges `patch` into the stored config. Returns false if the write failed. */
  function updateConfig(patch) {
    const merged = Object.assign({ host: null, port: BULB_PORT, lang: 'en', shortcut: 'None', shortcutKeyCode: 0, shortcutModifiers: 0 }, loadConfig() || {}, patch);
    const tmp = `${configPath}.${process.pid}.tmp`;
    try {
      fs.writeFileSync(tmp, JSON.stringify(merged, null, 2));
      fs.renameSync(tmp, configPath);
      return true;
    } catch (e) {
      log(`[Config] Failed to save config: ${e.message}`);
      try { fs.unlinkSync(tmp); } catch (_) {}
      return false;
    }
  }

  // --- Rate limiting: token bucket + latest-wins coalescing per method ---
  const bucket = { tokens: COMMAND_BURST, last: Date.now() };
  const queued = new Map();
  let flushTimer = null;

  function refill() {
    const now = Date.now();
    bucket.tokens = Math.min(COMMAND_BURST, bucket.tokens + ((now - bucket.last) * COMMAND_QUOTA_PER_MINUTE) / 60000);
    bucket.last = now;
  }

  function takeToken(reserve = 0) {
    refill();
    if (bucket.tokens >= 1 + reserve) {
      bucket.tokens -= 1;
      return true;
    }
    return false;
  }

  function flushQueue() {
    flushTimer = null;
    while (queued.size > 0) {
      if (!connected) {
        queued.clear();
        return;
      }
      if (!takeToken()) {
        const waitMs = Math.ceil(((1 - bucket.tokens) * 60000) / COMMAND_QUOTA_PER_MINUTE);
        flushTimer = setTimeout(flushQueue, Math.max(waitMs, 20));
        return;
      }
      const [method, params] = queued.entries().next().value;
      queued.delete(method);
      writeCmd(method, params);
    }
  }

  function enqueueCommand(method, params) {
    if (method === 'set_scene') SUPERSEDED_BY_SCENE.forEach((m) => queued.delete(m));
    queued.delete(method); // re-insert so the newest value goes last
    queued.set(method, params);
    if (!flushTimer) flushQueue();
  }

  // --- Yeelight TCP client ---
  function writeCmd(method, params) {
    if (!socket || !connected) return null;
    const id = nextId;
    nextId = nextId >= 2147483647 ? 1 : nextId + 1;
    try {
      socket.write(JSON.stringify({ id, method, params }) + '\r\n');
      return id;
    } catch (e) {
      return null;
    }
  }

  function queryProps() {
    const id = writeCmd('get_prop', PROP_KEYS);
    if (id !== null) {
      pendingPropIds.add(id);
      if (pendingPropIds.size > 32) pendingPropIds.delete(pendingPropIds.values().next().value);
    }
  }

  function handleData(data) {
    dataBuffer += data.toString('utf8');
    if (dataBuffer.length > 64 * 1024) dataBuffer = '';
    const lines = dataBuffer.split('\r\n');
    dataBuffer = lines.pop();

    for (const line of lines) {
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (e) {
        continue;
      }
      if (Array.isArray(msg.result) && pendingPropIds.has(msg.id)) {
        pendingPropIds.delete(msg.id);
        PROP_KEYS.forEach((k, i) => {
          if (msg.result[i] !== undefined && msg.result[i] !== '') props[k] = String(msg.result[i]);
        });
      } else if (msg.error && pendingPropIds.has(msg.id)) {
        pendingPropIds.delete(msg.id);
      }
      if (msg.method === 'props' && msg.params && typeof msg.params === 'object') {
        for (const [k, v] of Object.entries(msg.params)) {
          if (PROP_KEYS.includes(k)) props[k] = String(v);
        }
      }
    }
  }

  function connectDevice(host, bulbPort) {
    return new Promise((resolve, reject) => {
      if (socket) {
        try { socket.destroy(); } catch (e) {}
      }
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
      connected = false;
      pendingPropIds.clear();
      dataBuffer = '';
      device = { host, port: Number(bulbPort) };

      const s = new net.Socket();
      socket = s;
      let settled = false;
      s.setTimeout(5000);

      s.connect(Number(bulbPort), host, () => {
        if (s !== socket) return;
        s.setTimeout(0);
        s.setKeepAlive(true, 10000);
        connected = true;
        settled = true;
        reconnectAttempts = 0;
        log(`[Yeelight] Connected to ${host}:${bulbPort}`);
        updateConfig({ host, port: Number(bulbPort) });
        queryProps();
        resolve();
      });

      s.on('data', (d) => { if (s === socket) handleData(d); });
      s.on('timeout', () => {
        log('[Yeelight] Connection timeout');
        s.destroy(new Error('timeout'));
      });
      s.on('error', (err) => {
        if (s !== socket) return;
        log(`[Yeelight] Socket error: ${err.message}`);
        if (!settled) {
          settled = true;
          reject(err);
        }
      });
      s.on('close', () => {
        if (s !== socket) return;
        const wasConnected = connected;
        connected = false;
        if (!settled) {
          settled = true;
          reject(new Error('connection closed'));
        }
        if (wasConnected) {
          log('[Yeelight] Disconnected');
          scheduleReconnect();
        }
      });
    });
  }

  // --- Automatic reconnection with backoff and periodic re-discovery ---
  function scheduleReconnect() {
    if (manualDisconnect || !device.host || reconnectTimer || closed) return;
    const delay = Math.min(reconnectMaxMs, reconnectBaseMs * 2 ** Math.min(reconnectAttempts, 5));
    reconnectAttempts++;
    const attempt = reconnectAttempts;
    log(`[Yeelight] Reconnecting in ${delay} ms (attempt ${attempt})`);
    reconnectTimer = setTimeout(async () => {
      reconnectTimer = null;
      if (manualDisconnect || closed) return;
      try {
        await connectDevice(device.host, device.port);
        return;
      } catch (e) {
        // fall through
      }
      // Every third failed attempt the bulb may have a new DHCP lease: look for it.
      if (attempt % 3 === 0) {
        const lastHost = device.host;
        const found = await scanNetworkImpl().catch(() => []);
        const target = found.find((d) => d.host === lastHost) || found[0];
        if (target && !manualDisconnect && !closed) {
          try {
            await connectDevice(target.host, target.port);
            return;
          } catch (e) {
            // fall through
          }
        }
      }
      scheduleReconnect();
    }, delay);
  }

  // --- HTTP API ---
  function parseBody(req) {
    return new Promise((resolve) => {
      const chunks = [];
      let size = 0;
      let tooLarge = false;
      req.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX_BODY_BYTES) {
          tooLarge = true;
          return;
        }
        chunks.push(chunk);
      });
      req.on('end', () => {
        if (tooLarge) return resolve(null);
        try {
          const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          resolve(parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null);
        } catch (e) {
          resolve(null);
        }
      });
      req.on('error', () => resolve(null));
    });
  }

  function jsonRes(res, data, status = 200) {
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Yeelight-QuickControl': '1'
    });
    res.end(JSON.stringify(data));
  }

  function getHTML() {
    try {
      return fs.readFileSync(path.join(__dirname, 'dashboard.html'), 'utf8');
    } catch (e) {
      return '<h1>Error loading UI</h1>';
    }
  }

  let scanInFlight = null;
  function sharedScan() {
    if (!scanInFlight) {
      scanInFlight = scanNetworkImpl().finally(() => { scanInFlight = null; });
    }
    return scanInFlight;
  }

  async function route(req, res) {
    // Reject DNS-rebinding and cross-site requests: only our own loopback
    // origin may talk to this controller.
    if (!allowedHosts.has(String(req.headers.host || '').toLowerCase())) {
      return jsonRes(res, { error: 'host not allowed' }, 403);
    }
    const origin = req.headers.origin;
    if (origin && !allowedOrigins.has(origin)) {
      return jsonRes(res, { error: 'origin not allowed' }, 403);
    }
    // Requiring JSON on POST forces a CORS preflight, so a foreign page cannot
    // fire state-changing requests with a plain form or <img>.
    if (req.method === 'POST' && !String(req.headers['content-type'] || '').startsWith('application/json')) {
      return jsonRes(res, { error: 'content-type must be application/json' }, 415);
    }
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': origin || `http://127.0.0.1:${port}`,
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type'
      });
      return res.end();
    }

    const url = req.url.split('?')[0];

    if (url === '/' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      return res.end(getHTML());
    }

    if (url === '/api/health' && req.method === 'GET') {
      return jsonRes(res, { ok: true, service: 'yeelight-quickcontrol' });
    }

    if (url === '/api/status' && req.method === 'GET') {
      const cfg = loadConfig();
      return jsonRes(res, {
        connected,
        reconnecting: !connected && reconnectTimer !== null,
        device: device.host ? device : null,
        hasConfig: cfg !== null,
        lang: cfg && ALLOWED_LANGUAGES.has(cfg.lang) ? cfg.lang : 'en',
        shortcut: cfg ? (cfg.shortcut || 'None') : 'None',
        shortcutKeyCode: cfg ? (cfg.shortcutKeyCode || 0) : 0,
        shortcutModifiers: cfg ? (cfg.shortcutModifiers || 0) : 0,
        // null (not defaults) when never saved: the dashboard shows localized defaults.
        favorites: cfg && Array.isArray(cfg.favorites) ? cfg.favorites : null,
        props
      });
    }

    // Scanning is a POST so that a simple cross-site GET cannot trigger it.
    if (url === '/api/scan' && req.method === 'POST') {
      const devices = await sharedScan();
      return jsonRes(res, { devices });
    }

    if (url === '/api/connect' && req.method === 'POST') {
      const body = await parseBody(req);
      if (!body || !body.host) return jsonRes(res, { error: 'valid JSON body and host required' }, 400);
      const host = String(body.host).trim();
      const bulbPort = body.port === undefined ? BULB_PORT : Number(body.port);
      if (net.isIP(host) !== 4 || !Number.isInteger(bulbPort) || bulbPort < 1 || bulbPort > 65535) {
        return jsonRes(res, { error: 'invalid host or port' }, 400);
      }
      manualDisconnect = false;
      try {
        await connectDevice(host, bulbPort);
        return jsonRes(res, { ok: true });
      } catch (e) {
        return jsonRes(res, { error: e.message }, 502);
      }
    }

    if (url === '/api/disconnect' && req.method === 'POST') {
      manualDisconnect = true;
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
      queued.clear();
      const s = socket;
      socket = null;
      connected = false;
      device = { host: null, port: BULB_PORT };
      if (s) {
        try { s.destroy(); } catch (e) {}
      }
      return jsonRes(res, { ok: true });
    }

    if (url === '/api/command' && req.method === 'POST') {
      const body = await parseBody(req);
      if (!body) return jsonRes(res, { error: 'valid JSON body required' }, 400);
      const result = validateCommand(body.method, body.params);
      if (result.error) return jsonRes(res, { error: result.error }, 400);
      if (!connected) return jsonRes(res, { error: 'device is not connected' }, 503);

      const params = result.params;
      enqueueCommand(body.method, params);

      // Optimistic local state for immediate UI feedback; the bulb's "props"
      // notifications correct it if the command fails.
      if (body.method === 'set_power') props.power = params[0];
      if (body.method === 'set_bright') props.bright = String(params[0]);
      if (body.method === 'set_hsv') {
        props.hue = String(params[0]);
        props.sat = String(params[1]);
        props.color_mode = '3';
      }
      if (body.method === 'set_ct_abx') {
        props.ct = String(params[0]);
        props.color_mode = '2';
      }
      if (body.method === 'set_scene') {
        props.power = 'on';
        props.bright = String(params[params.length - 1]);
        if (params[0] === 'ct') {
          props.ct = String(params[1]);
          props.color_mode = '2';
        } else {
          props.hue = String(params[1]);
          props.sat = String(params[2]);
          props.color_mode = '3';
        }
      }
      return jsonRes(res, { ok: true });
    }

    if (url === '/api/favorites' && req.method === 'POST') {
      const body = await parseBody(req);
      const favorites = body ? sanitizeFavorites(body.favorites) : null;
      if (!favorites) return jsonRes(res, { error: 'invalid favorites' }, 400);
      if (!updateConfig({ favorites })) return jsonRes(res, { error: 'could not save settings' }, 500);
      return jsonRes(res, { ok: true, favorites });
    }

    if (url === '/api/language' && req.method === 'POST') {
      const body = await parseBody(req);
      if (!body || !ALLOWED_LANGUAGES.has(body.lang)) return jsonRes(res, { error: 'unsupported language' }, 400);
      if (!updateConfig({ lang: body.lang })) return jsonRes(res, { error: 'could not save settings' }, 500);
      return jsonRes(res, { ok: true });
    }

    if (url === '/api/shortcut' && req.method === 'POST') {
      const body = await parseBody(req);
      if (!body || typeof body.shortcut !== 'string' || body.shortcut.length > 80 || !body.shortcut.trim()) {
        return jsonRes(res, { error: 'valid shortcut required' }, 400);
      }
      const keyCode = body.keyCode === undefined ? 0 : Number(body.keyCode);
      const modifiers = body.modifiers === undefined ? 0 : Number(body.modifiers);
      if (!Number.isInteger(keyCode) || keyCode < 0 || keyCode > 127 || !Number.isInteger(modifiers) || modifiers < 0 || modifiers > 65535) {
        return jsonRes(res, { error: 'invalid shortcut key data' }, 400);
      }
      if (!updateConfig({ shortcut: body.shortcut, shortcutKeyCode: keyCode, shortcutModifiers: modifiers })) {
        return jsonRes(res, { error: 'could not save settings' }, 500);
      }
      return jsonRes(res, { ok: true });
    }

    return jsonRes(res, { error: 'not found' }, 404);
  }

  const server = http.createServer((req, res) => {
    route(req, res).catch((e) => {
      log(`[HTTP] ${req.method} ${req.url} failed: ${e && e.stack ? e.stack : e}`);
      if (!res.headersSent) jsonRes(res, { error: 'internal error' }, 500);
      else res.end();
    });
  });

  const pollTimer = setInterval(() => {
    // State changes arrive as "props" notifications, so this is only a slow
    // heartbeat. Skip it when user commands need the quota.
    if (connected && queued.size === 0 && takeToken(POLL_TOKEN_RESERVE)) queryProps();
  }, POLL_INTERVAL_MS);
  pollTimer.unref();

  function listen() {
    return new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, '127.0.0.1', () => {
        server.off('error', reject);
        resolve(server.address().port);
      });
    });
  }

  async function autoConnect() {
    const cfg = loadConfig();
    if (!cfg || !cfg.host) {
      log('[Yeelight QuickControl] Ready. No saved device configured yet.');
      return;
    }
    log(`[Yeelight QuickControl] Auto-connecting to ${cfg.host}:${cfg.port}...`);
    try {
      await connectDevice(cfg.host, cfg.port || BULB_PORT);
      return;
    } catch (e) {
      log('[Yeelight QuickControl] Auto-connect failed. Scanning network for bulb...');
    }
    const found = await scanNetworkImpl().catch(() => []);
    const target = found.find((d) => d.host === cfg.host) || found[0];
    if (target) {
      try {
        await connectDevice(target.host, target.port);
        return;
      } catch (e) {
        // fall through to background retries
      }
    }
    device = { host: cfg.host, port: Number(cfg.port) || BULB_PORT };
    scheduleReconnect();
  }

  function close() {
    closed = true;
    clearInterval(pollTimer);
    clearTimeout(reconnectTimer);
    clearTimeout(flushTimer);
    if (socket) socket.destroy();
    return new Promise((resolve) => server.close(() => resolve()));
  }

  return {
    server,
    listen,
    autoConnect,
    close,
    connectDevice,
    get state() {
      return { connected, device: { ...device }, props: { ...props }, reconnecting: reconnectTimer !== null, queued: queued.size };
    }
  };
}

// --- Network discovery ---

/** SSDP multicast discovery (Yeelight answers M-SEARCH sent to 239.255.255.250:1982). */
function scanSSDP(timeoutMs = 1500) {
  return new Promise((resolve) => {
    const found = [];
    const seen = new Set();
    const client = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    const msg = Buffer.from('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: "ssdp:discover"\r\nST: wifi_bulb\r\n\r\n');
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      try { client.close(); } catch (e) {}
      resolve(found);
    };

    client.on('message', (buffer) => {
      const m = buffer.toString('utf8').match(/Location:\s*yeelight:\/\/([\d.]+):(\d+)/i);
      if (!m) return;
      const key = `${m[1]}:${m[2]}`;
      if (!seen.has(key)) {
        seen.add(key);
        found.push({ host: m[1], port: Number(m[2]) });
      }
    });
    client.on('error', finish);
    client.bind(() => {
      client.send(msg, 1982, '239.255.255.250', (err) => {
        if (err) return finish();
        // Repeat once; multicast on Wi-Fi is lossy.
        setTimeout(() => { if (!done) client.send(msg, 1982, '239.255.255.250', () => {}); }, 300);
      });
      setTimeout(finish, timeoutMs);
    });
  });
}

/**
 * Probes one host: TCP connect to 55443, then confirm it speaks the Yeelight
 * protocol by asking for a property. Other devices with that port open are
 * ignored.
 */
function probeYeelight(host, timeoutMs = 700, bulbPort = BULB_PORT) {
  return new Promise((resolve) => {
    const s = new net.Socket();
    let buffer = '';
    let done = false;
    const finish = (ok) => {
      if (done) return;
      done = true;
      s.destroy();
      resolve(ok);
    };
    s.setTimeout(timeoutMs, () => finish(false));
    s.on('error', () => finish(false));
    s.on('close', () => finish(false));
    s.on('data', (d) => {
      buffer += d.toString('utf8');
      if (/"id"\s*:\s*1\b/.test(buffer) && /"(result|error)"/.test(buffer)) finish(true);
      if (buffer.length > 4096) finish(false);
    });
    s.connect(bulbPort, host, () => {
      s.write(JSON.stringify({ id: 1, method: 'get_prop', params: ['power'] }) + '\r\n');
    });
  });
}

async function scanSubnetTCP() {
  const targets = new Set();
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    if (IGNORED_INTERFACES.test(name)) continue;
    for (const iface of ifaces[name] || []) {
      if (iface.family === 'IPv4' && !iface.internal) {
        hostsForInterface(iface.address, iface.netmask).forEach((h) => targets.add(h));
      }
    }
  }
  const hosts = [...targets];
  const found = [];
  const CONCURRENCY = 128;
  for (let i = 0; i < hosts.length; i += CONCURRENCY) {
    const batch = hosts.slice(i, i + CONCURRENCY);
    const results = await Promise.all(batch.map((h) => probeYeelight(h)));
    results.forEach((ok, j) => { if (ok) found.push({ host: batch[j], port: BULB_PORT }); });
  }
  return found;
}

async function scanNetwork() {
  try {
    const ssdp = await scanSSDP();
    if (ssdp.length > 0) return ssdp;
  } catch (e) {
    // fall back to TCP scan
  }
  return scanSubnetTCP();
}

module.exports = { createController, validateCommand, sanitizeFavorites, hostsForInterface, probeYeelight, scanNetwork };

if (require.main === module) {
  const port = Number(process.env.YEELIGHT_QUICKCONTROL_PORT) || DEFAULT_PORT;
  const controller = createController({ port });
  controller.listen().then(() => {
    const url = `http://127.0.0.1:${port}`;
    console.log(`[Yeelight QuickControl] Local controller running at ${url}`);
    controller.autoConnect().catch((e) => console.log(`[Yeelight QuickControl] Auto-connect error: ${e.message}`));
    if (!process.env.YEELIGHT_QUICKCONTROL_NO_BROWSER && process.platform === 'darwin') {
      execFile('open', [url], () => {});
    }
  }).catch((e) => {
    console.error(`[Yeelight QuickControl] Could not listen on port ${port}: ${e.message}`);
    process.exit(1);
  });
  const shutdown = () => controller.close().then(() => process.exit(0));
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

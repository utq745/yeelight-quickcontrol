#!/usr/bin/env node

/**
 * Yeelight QuickControl — Lightweight Yeelight Controller
 * Zero-dependency Node.js background controller for Yeelight smart bulbs.
 */

const http = require('http');
const net = require('net');
const dgram = require('dgram');
const os = require('os');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');

const PORT = 7655;
const CONFIG_PATH = path.join(os.homedir(), '.yeelight-quickcontrol.json');
const LEGACY_CONFIG_PATH = path.join(os.homedir(), '.smart-lights.json');
const MAX_BODY_BYTES = 16 * 1024;
const ALLOWED_LANGUAGES = new Set(['en', 'tr', 'fr', 'pt', 'zh', 'de', 'it']);
const ALLOWED_COMMANDS = new Set(['set_power', 'set_bright', 'set_hsv', 'set_ct_abx']);
const ALLOWED_ORIGINS = new Set([
  `http://127.0.0.1:${PORT}`,
  `http://localhost:${PORT}`
]);

// --- Device State ---
let device = { host: null, port: 55443 };
let socket = null;
let connected = false;
let cmdId = 1;
let dataBuffer = '';
let props = {
  power: 'off',
  bright: '100',
  ct: '4000',
  rgb: '16777215',
  hue: '0',
  sat: '100',
  color_mode: '2'
};

// --- Configuration Management ---
function loadConfig() {
  try {
    const configPath = fs.existsSync(CONFIG_PATH) ? CONFIG_PATH : LEGACY_CONFIG_PATH;
    if (fs.existsSync(configPath)) {
      return JSON.parse(fs.readFileSync(configPath, 'utf8'));
    }
  } catch (e) {
    // Ignore read/parse errors
  }
  return null;
}

function saveConfig(host, port) {
  const cfg = loadConfig() || {};
  fs.writeFileSync(CONFIG_PATH, JSON.stringify({
    host,
    port: Number(port),
    lang: cfg.lang || 'en',
    shortcut: cfg.shortcut || 'None',
    shortcutKeyCode: cfg.shortcutKeyCode || 0,
    shortcutModifiers: cfg.shortcutModifiers || 0
  }, null, 2));
}

// --- Yeelight TCP Client ---
function connectDevice(host, port) {
  return new Promise((resolve, reject) => {
    if (socket) {
      try { socket.destroy(); } catch (e) {}
    }
    connected = false;
    device = { host, port: Number(port) };

    socket = new net.Socket();
    socket.setTimeout(5000);

    socket.connect(Number(port), host, () => {
      socket.setTimeout(0); // Disable timeout after successful connection
      connected = true;
      dataBuffer = '';
      console.log(`[Yeelight] Connected to ${host}:${port}`);
      saveConfig(host, port);
      
      // Fetch initial bulb properties
      sendCmd('get_prop', ['power', 'bright', 'ct', 'rgb', 'hue', 'sat', 'color_mode']);
      resolve();
    });

    socket.on('data', handleData);
    socket.on('error', (err) => {
      console.log(`[Yeelight] Socket error: ${err.message}`);
      connected = false;
      reject(err);
    });
    socket.on('close', () => {
      connected = false;
      console.log('[Yeelight] Disconnected');
    });
    socket.on('timeout', () => {
      console.log('[Yeelight] Connection timeout');
      socket.destroy();
      connected = false;
      reject(new Error('timeout'));
    });
  });
}

function handleData(data) {
  dataBuffer += data.toString('utf8');
  const lines = dataBuffer.split('\r\n');
  dataBuffer = lines.pop(); // Keep incomplete line in buffer

  for (const line of lines) {
    if (!line) continue;
    try {
      const msg = JSON.parse(line);
      // Property query response
      if (msg.result && Array.isArray(msg.result)) {
        if (msg.id === 199 || msg.id === 100) {
          const keys = ['power', 'bright', 'ct', 'rgb', 'hue', 'sat', 'color_mode'];
          keys.forEach((k, i) => {
            if (msg.result[i] !== undefined && msg.result[i] !== '') {
              props[k] = msg.result[i];
            }
          });
        }
      }
      // Notification pushed when bulb state changes
      if (msg.method === 'props' && msg.params) {
        Object.assign(props, msg.params);
      }
    } catch (e) {
      // Ignore parse errors on partial frames
    }
  }
}

function sendCmd(method, params) {
  if (!socket || !connected) return false;
  const id = method === 'get_prop' ? 100 : cmdId++;
  const cmd = JSON.stringify({ id, method, params }) + '\r\n';
  try {
    socket.write(cmd);
    return true;
  } catch (e) {
    return false;
  }
}

// Periodic background polling (every 3s)
setInterval(() => {
  if (connected) {
    sendCmd('get_prop', ['power', 'bright', 'ct', 'rgb', 'hue', 'sat', 'color_mode']);
  }
}, 3000);

// --- Network Discovery ---

/**
 * Fast SSDP UDP Multicast discovery for Yeelight bulbs.
 */
function scanSSDP(timeoutMs = 1200) {
  return new Promise((resolve) => {
    const found = [];
    const seen = new Set();
    const client = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    const msg = 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: "ssdp:discover"\r\nST: wifi_bulb\r\n';

    client.on('message', (buffer) => {
      const str = buffer.toString('utf8');
      const locMatch = str.match(/Location:\s*yeelight:\/\/([^:]+):(\d+)/i);
      if (locMatch) {
        const host = locMatch[1];
        const port = Number(locMatch[2]);
        const key = `${host}:${port}`;
        if (!seen.has(key)) {
          seen.add(key);
          found.push({ host, port });
        }
      }
    });

    client.on('error', () => {
      try { client.close(); } catch (e) {}
      resolve(found);
    });

    client.bind(() => {
      try {
        client.setBroadcast(true);
        client.send(msg, 0, msg.length, 1982, '239.255.255.250');
      } catch (e) {
        try { client.close(); } catch (err) {}
        resolve(found);
        return;
      }

      setTimeout(() => {
        try { client.close(); } catch (e) {}
        resolve(found);
      }, timeoutMs);
    });
  });
}

/**
 * Fallback subnet TCP port 55443 scanner.
 */
function scanSubnetTCP() {
  return new Promise((resolve) => {
    const found = [];
    let pending = 0;
    const subnets = [];

    const ifaces = os.networkInterfaces();
    for (const name of Object.keys(ifaces)) {
      for (const iface of ifaces[name]) {
        if (iface.family === 'IPv4' && !iface.internal) {
          const parts = iface.address.split('.');
          const subnet = `${parts[0]}.${parts[1]}.${parts[2]}`;
          if (!subnets.includes(subnet)) subnets.push(subnet);
        }
      }
    }

    if (subnets.length === 0) {
      resolve(found);
      return;
    }

    for (const subnet of subnets) {
      for (let i = 1; i <= 254; i++) {
        pending++;
        const ip = `${subnet}.${i}`;
        const s = new net.Socket();
        s.setTimeout(600);

        s.on('connect', () => {
          found.push({ host: ip, port: 55443 });
          s.destroy();
        });
        s.on('timeout', () => s.destroy());
        s.on('error', () => s.destroy());
        s.on('close', () => {
          pending--;
          if (pending === 0) resolve(found);
        });
        s.connect(55443, ip);
      }
    }
  });
}

async function scanNetwork() {
  try {
    const ssdpDevices = await scanSSDP(1200);
    if (ssdpDevices.length > 0) return ssdpDevices;
  } catch (e) {
    // Fallback to TCP scanning if SSDP multicast fails
  }
  return scanSubnetTCP();
}

// --- HTTP API Server ---
function parseBody(req) {
  return new Promise((resolve) => {
    let body = '';
    let size = 0;
    let tooLarge = false;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        tooLarge = true;
        return;
      }
      body += chunk;
    });
    req.on('end', () => {
      if (tooLarge) {
        resolve(null);
        return;
      }
      try {
        const parsed = JSON.parse(body);
        resolve(parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null);
      } catch (e) {
        resolve(null);
      }
    });
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

const server = http.createServer(async (req, res) => {
  const origin = req.headers.origin;
  if (origin && !ALLOWED_ORIGINS.has(origin)) {
    return jsonRes(res, { error: 'origin not allowed' }, 403);
  }

  // CORS Preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': origin || `http://127.0.0.1:${PORT}`,
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type'
    });
    return res.end();
  }

  const url = req.url.split('?')[0];

  // Web Dashboard UI
  if (url === '/' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(getHTML());
  }

  // Process health check used by the native wrapper before spawning Node.
  if (url === '/api/health' && req.method === 'GET') {
    return jsonRes(res, { ok: true, service: 'yeelight-quickcontrol' });
  }

  // API: Get Current Status
  if (url === '/api/status' && req.method === 'GET') {
    const cfg = loadConfig();
    return jsonRes(res, {
      connected,
      device: device.host ? device : null,
      hasConfig: cfg !== null,
      lang: cfg && ALLOWED_LANGUAGES.has(cfg.lang) ? cfg.lang : 'en',
      shortcut: cfg ? (cfg.shortcut || 'None') : 'None',
      shortcutKeyCode: cfg ? (cfg.shortcutKeyCode || 0) : 0,
      shortcutModifiers: cfg ? (cfg.shortcutModifiers || 0) : 0,
      props
    });
  }

  // API: Scan Local Network
  if (url === '/api/scan' && req.method === 'GET') {
    const devices = await scanNetwork();
    return jsonRes(res, { devices });
  }

  // API: Connect to Device
  if (url === '/api/connect' && req.method === 'POST') {
    const body = await parseBody(req);
    if (!body || !body.host) return jsonRes(res, { error: 'valid JSON body and host required' }, 400);
    const host = String(body.host).trim();
    const port = body.port === undefined ? 55443 : Number(body.port);
    if (net.isIP(host) !== 4 || !Number.isInteger(port) || port < 1 || port > 65535) {
      return jsonRes(res, { error: 'invalid host or port' }, 400);
    }
    try {
      await connectDevice(host, port);
      return jsonRes(res, { ok: true });
    } catch (e) {
      return jsonRes(res, { error: e.message }, 500);
    }
  }

  // API: Disconnect Device
  if (url === '/api/disconnect' && req.method === 'POST') {
    if (socket) {
      try { socket.destroy(); } catch (e) {}
    }
    connected = false;
    device = { host: null, port: 55443 };
    return jsonRes(res, { ok: true });
  }

  // API: Send Command to Device
  if (url === '/api/command' && req.method === 'POST') {
    const body = await parseBody(req);
    if (!body || !body.method || !ALLOWED_COMMANDS.has(body.method) || !Array.isArray(body.params)) {
      return jsonRes(res, { error: 'unsupported method or invalid params' }, 400);
    }

    const params = body.params;
    if (body.method === 'set_power' && !['on', 'off'].includes(params[0])) {
      return jsonRes(res, { error: 'power must be on or off' }, 400);
    }
    if (body.method === 'set_bright' && (!Number.isFinite(Number(params[0])) || Number(params[0]) < 1 || Number(params[0]) > 100)) {
      return jsonRes(res, { error: 'brightness must be between 1 and 100' }, 400);
    }
    if (body.method === 'set_hsv' && (!Number.isFinite(Number(params[0])) || Number(params[0]) < 0 || Number(params[0]) > 359 || !Number.isFinite(Number(params[1])) || Number(params[1]) < 0 || Number(params[1]) > 100)) {
      return jsonRes(res, { error: 'hue or saturation is out of range' }, 400);
    }
    if (body.method === 'set_ct_abx' && (!Number.isFinite(Number(params[0])) || Number(params[0]) < 1700 || Number(params[0]) > 6500)) {
      return jsonRes(res, { error: 'color temperature must be between 1700 and 6500' }, 400);
    }

    const ok = sendCmd(body.method, params);
    if (!ok) return jsonRes(res, { error: 'device is not connected' }, 503);

    // Optimistically update local state for immediate responsiveness
    if (body.method === 'set_power') props.power = params[0];
    if (body.method === 'set_bright') props.bright = String(params[0]);
    if (body.method === 'set_hsv') {
      props.hue = String(params[0]);
      props.sat = String(params[1]);
      props.color_mode = '1';
    }
    if (body.method === 'set_ct_abx') {
      props.ct = String(params[0]);
      props.color_mode = '2';
    }

    return jsonRes(res, { ok });
  }

  // API: Update Preferred Language
  if (url === '/api/language' && req.method === 'POST') {
    const body = await parseBody(req);
    if (!body || !ALLOWED_LANGUAGES.has(body.lang)) return jsonRes(res, { error: 'unsupported language' }, 400);
    const cfg = loadConfig() || { host: null, port: 55443 };
    cfg.lang = body.lang;
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2));
    return jsonRes(res, { ok: true });
  }

  // API: Update Global Shortcut
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
    const cfg = loadConfig() || { host: null, port: 55443, lang: 'en' };
    cfg.shortcut = body.shortcut;
    cfg.shortcutKeyCode = keyCode;
    cfg.shortcutModifiers = modifiers;
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2));
    return jsonRes(res, { ok: true });
  }

  // 404 Fallback
  jsonRes(res, { error: 'not found' }, 404);
});

// --- Server Lifecycle ---
server.listen(PORT, '127.0.0.1', () => {
  console.log(`[Yeelight QuickControl] Local controller running at http://127.0.0.1:${PORT}`);

  const cfg = loadConfig();
  if (cfg && cfg.host) {
    console.log(`[Yeelight QuickControl] Auto-connecting to ${cfg.host}:${cfg.port}...`);
    connectDevice(cfg.host, cfg.port).catch(async () => {
      console.log('[Yeelight QuickControl] Auto-connect failed. Scanning network for bulb...');
      const found = await scanNetwork();
      if (found.length > 0) {
        const target = found[0];
        console.log(`[Yeelight QuickControl] Auto-recovery: Found Yeelight at ${target.host}. Connecting...`);
        connectDevice(target.host, target.port).catch(() => {});
      } else {
        console.log('[Yeelight QuickControl] No Yeelight devices detected during recovery scan.');
      }
    });
  } else {
    console.log('[Yeelight QuickControl] Ready. No saved device configured yet.');
  }

  // Open browser only when running in standalone mode (not inside macOS .app wrapper)
  if (!process.env.YEELIGHT_QUICKCONTROL_EMBEDDED) {
    exec(`open http://127.0.0.1:${PORT}`);
  }
});

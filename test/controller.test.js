'use strict';

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const net = require('net');
const path = require('path');
const { probeYeelight } = require('../server.js');
const { FakeBulb } = require('./fake-bulb.js');
const { startController, waitFor, sleep, freePort } = require('./helpers.js');

/** Runs fn with a fresh controller + started fake bulb, always cleaning up. */
async function withSetup(fn, { ctrlOpts = {}, bulbOpts = {} } = {}) {
  const bulb = new FakeBulb(bulbOpts);
  await bulb.start();
  const api = await startController(ctrlOpts);
  try {
    await fn({ api, bulb });
  } finally {
    await api.close();
    await bulb.stop();
  }
}

const nonPropCommands = (bulb) => bulb.received.filter((m) => m.method !== 'get_prop');

describe('HTTP security', () => {
  let api;
  before(async () => { api = await startController(); });
  after(async () => { await api.close(); });

  test('allowed host + no origin is served', async () => {
    const r = await api.req('GET', '/api/health');
    assert.equal(r.status, 200);
    assert.equal(r.body.ok, true);
    const r2 = await api.req('GET', '/api/health', { headers: { Host: `localhost:${api.port}` } });
    assert.equal(r2.status, 200);
  });

  test('wrong Host header -> 403', async () => {
    for (const host of ['evil.example.com', `evil.example.com:${api.port}`, '127.0.0.1:1', `127.0.0.1:${api.port}.evil.com`]) {
      const r = await api.req('GET', '/api/status', { headers: { Host: host } });
      assert.equal(r.status, 403, `host ${host}`);
    }
  });

  test('foreign Origin -> 403, own origin allowed', async () => {
    const r = await api.req('GET', '/api/status', { headers: { Origin: 'http://evil.example.com' } });
    assert.equal(r.status, 403);
    const r2 = await api.req('POST', '/api/language', { body: { lang: 'de' }, headers: { Origin: 'http://evil.example.com' } });
    assert.equal(r2.status, 403);
    const r3 = await api.req('GET', '/api/status', { headers: { Origin: `http://127.0.0.1:${api.port}` } });
    assert.equal(r3.status, 200);
  });

  test('POST without application/json content-type -> 415', async () => {
    const r = await api.req('POST', '/api/language', { body: '{"lang":"de"}', headers: { 'Content-Type': 'text/plain' } });
    assert.equal(r.status, 415);
    const r2 = await api.req('POST', '/api/disconnect', { body: 'x=1', headers: { 'Content-Type': 'application/x-www-form-urlencoded' } });
    assert.equal(r2.status, 415);
  });

  test('GET /api/scan -> 404 (POST-only)', async () => {
    let scans = 0;
    const local = await startController({ scanNetwork: async () => { scans++; return []; } });
    try {
      const r = await local.req('GET', '/api/scan');
      assert.equal(r.status, 404);
      assert.equal(scans, 0);
      const r2 = await local.req('POST', '/api/scan', { body: {} });
      assert.equal(r2.status, 200);
      assert.deepEqual(r2.body.devices, []);
      assert.equal(scans, 1);
    } finally {
      await local.close();
    }
  });

  test('command validation errors -> 400, not connected -> 503', async () => {
    const bad = await api.command('set_bright', [0]);
    assert.equal(bad.status, 400);
    const r = await api.command('set_bright', [50]);
    assert.equal(r.status, 503);
  });
});

describe('device connection', () => {
  test('POST /api/connect -> /api/status shows connected and get_prop props', async () => {
    await withSetup(async ({ api, bulb }) => {
      const r = await api.connect(bulb.port);
      assert.equal(r.status, 200);
      const st = await waitFor(async () => {
        const s = await api.status();
        return s.connected && s.props.bright === '42' ? s : null;
      }, { message: 'props from get_prop' });
      assert.equal(st.reconnecting, false);
      assert.deepEqual(st.device, { host: '127.0.0.1', port: bulb.port });
      assert.deepEqual(st.props, { power: 'on', bright: '42', ct: '3500', rgb: '255', hue: '120', sat: '80', color_mode: '2' });
      const cfg = JSON.parse(fs.readFileSync(api.configPath, 'utf8'));
      assert.equal(cfg.host, '127.0.0.1');
      assert.equal(cfg.port, bulb.port);
    }, { bulbOpts: {} });
  });

  test('connect to a closed port -> 502', async () => {
    const api = await startController();
    try {
      const r = await api.connect(await freePort());
      assert.equal(r.status, 502);
      assert.equal((await api.status()).connected, false);
    } finally {
      await api.close();
    }
  });

  test('command reply ids colliding with ids 100/199/old get_prop do not overwrite props', async () => {
    // Every non-get_prop command is answered with ids 100, 199, 1 (the
    // already-answered initial get_prop) and its own id, all with ["ok"].
    await withSetup(async ({ api, bulb }) => {
      await api.connect(bulb.port);
      await waitFor(async () => (await api.status()).props.bright === '42', { message: 'initial props' });

      const sends = [];
      for (let i = 0; i < 105; i++) {
        if (i % 3 === 0) sends.push(['set_power', [i % 2 ? 'on' : 'off']]);
        else if (i % 3 === 1) sends.push(['set_bright', [(i % 100) + 1]]);
        else sends.push(['set_ct_abx', [1700 + i * 10]]);
      }
      for (const [m, p] of sends) {
        const r = await api.command(m, p);
        assert.equal(r.status, 200);
      }
      await waitFor(() => nonPropCommands(bulb).length >= 15, { message: 'bulb receiving commands' });
      await sleep(150); // let the colliding replies arrive

      const st = await api.status();
      for (const [k, v] of Object.entries(st.props)) assert.notEqual(v, 'ok', `props.${k} was overwritten by a command reply`);
      const last = (m) => sends.filter((s) => s[0] === m).pop()[1][0];
      assert.equal(st.props.power, last('set_power'));
      assert.equal(st.props.bright, String(last('set_bright')));
      assert.equal(st.props.ct, String(last('set_ct_abx')));
      // untouched keys still come from get_prop
      assert.equal(st.props.rgb, '255');
      assert.equal(st.props.hue, '120');
    }, { bulbOpts: { replyIds: (msg) => [100, 199, 1, msg.id] } });
  });

  test('rate limiting: 40 rapid set_bright -> <=16 immediately, last value wins', async () => {
    await withSetup(async ({ api, bulb }) => {
      await api.connect(bulb.port);
      for (let v = 1; v <= 40; v++) {
        const r = await api.command('set_bright', [v]);
        assert.equal(r.status, 200);
      }
      await sleep(50);
      const immediate = bulb.commands('set_bright').length;
      assert.ok(immediate <= 16, `bulb received ${immediate} commands immediately`);
      assert.ok(immediate >= 10, `expected a burst, got ${immediate}`);

      await waitFor(() => {
        const cmds = bulb.commands('set_bright');
        return cmds.length && cmds[cmds.length - 1].params[0] === 40;
      }, { timeout: 3000, message: 'latest set_bright (40) to be delivered' });
      const total = bulb.commands('set_bright').length;
      assert.ok(total <= 17, `coalescing should collapse the backlog, got ${total}`);
      assert.equal((await api.status()).props.bright, '40');
    });
  });

  test('props notification from bulb updates /api/status', async () => {
    await withSetup(async ({ api, bulb }) => {
      await api.connect(bulb.port);
      await waitFor(async () => (await api.status()).props.bright === '42');
      bulb.pushProps({ power: 'off', bright: 7, ct: 2700, bogus_key: 'x' });
      const st = await waitFor(async () => {
        const s = await api.status();
        return s.props.bright === '7' ? s : null;
      }, { message: 'props notification' });
      assert.equal(st.props.power, 'off');
      assert.equal(st.props.ct, '2700');
      assert.equal(st.props.bogus_key, undefined);
    });
  });
});

describe('reconnect and re-discovery', () => {
  test('bulb drops sockets -> reconnecting:true, then reconnects', async () => {
    await withSetup(async ({ api, bulb }) => {
      await api.connect(bulb.port);
      assert.equal(bulb.connectionCount, 1);
      await waitFor(() => bulb.commands('get_prop').length === 1, { message: 'initial get_prop' });
      await bulb.stop();
      await waitFor(async () => {
        const s = await api.status();
        return !s.connected && s.reconnecting;
      }, { message: 'reconnecting:true' });
      await bulb.start(bulb.port);
      await waitFor(async () => (await api.status()).connected, { message: 'reconnected' });
      assert.ok(bulb.connectionCount >= 2);
      // re-queries props on reconnect
      await waitFor(() => bulb.commands('get_prop').length >= 2, { message: 'get_prop after reconnect' });
    });
  });

  test('dropping sockets while still listening reconnects quickly', async () => {
    await withSetup(async ({ api, bulb }) => {
      await api.connect(bulb.port);
      bulb.dropClients();
      await waitFor(() => bulb.connectionCount >= 2, { message: 'second connection' });
      await waitFor(async () => (await api.status()).connected, { message: 'connected again' });
    });
  });

  test('POST /api/disconnect stops reconnect attempts', async () => {
    await withSetup(async ({ api, bulb }) => {
      await api.connect(bulb.port);
      await bulb.stop();
      await waitFor(async () => (await api.status()).reconnecting, { message: 'reconnecting:true' });
      const r = await api.req('POST', '/api/disconnect', { body: {} });
      assert.equal(r.status, 200);
      const before = bulb.connectionCount;
      await bulb.start(bulb.port);
      await sleep(600); // several backoff periods (base 50, max 200)
      const st = await api.status();
      assert.equal(st.connected, false);
      assert.equal(st.reconnecting, false);
      assert.equal(st.device, null);
      assert.equal(bulb.connectionCount, before);
    });
  });

  test('after 3 failed attempts the scanned bulb on a new port is used and config updated', async () => {
    const newBulb = new FakeBulb({ props: { bright: '88' } });
    await newBulb.start();
    let scans = 0;
    try {
      await withSetup(async ({ api, bulb }) => {
        await api.connect(bulb.port);
        await bulb.stop();
        await waitFor(async () => {
          const s = await api.status();
          return s.connected && s.device.port === newBulb.port ? s : null;
        }, { timeout: 4000, message: 'connected to rediscovered bulb' });
        assert.ok(scans >= 1, 'scanNetwork should have been called');
        assert.equal(newBulb.connectionCount, 1);
        const cfg = JSON.parse(fs.readFileSync(api.configPath, 'utf8'));
        assert.equal(cfg.host, '127.0.0.1');
        assert.equal(cfg.port, newBulb.port);
        await waitFor(async () => (await api.status()).props.bright === '88', { message: 'props from new bulb' });
      }, { ctrlOpts: { scanNetwork: async () => { scans++; return [{ host: '127.0.0.1', port: newBulb.port }]; } } });
    } finally {
      await newBulb.stop();
    }
  });

  test('autoConnect uses the saved config', async () => {
    const bulb = new FakeBulb();
    await bulb.start();
    const { tmpDir } = require('./helpers.js');
    const dir = tmpDir();
    const configPath = path.join(dir, 'config.json');
    fs.writeFileSync(configPath, JSON.stringify({ host: '127.0.0.1', port: bulb.port, lang: 'fr' }));
    const api = await startController({ configPath });
    try {
      await api.ctrl.autoConnect();
      const st = await api.status();
      assert.equal(st.connected, true);
      assert.equal(st.lang, 'fr');
    } finally {
      await api.close();
      await bulb.stop();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('config persistence', () => {
  test('config write failure -> /api/language 500, server keeps serving', async () => {
    const { tmpDir } = require('./helpers.js');
    const dir = tmpDir();
    const api = await startController({ configPath: path.join(dir, 'does', 'not', 'exist', 'config.json') });
    try {
      const r = await api.req('POST', '/api/language', { body: { lang: 'de' } });
      assert.equal(r.status, 500);
      const r2 = await api.req('POST', '/api/shortcut', { body: { shortcut: 'Cmd+L', keyCode: 37, modifiers: 256 } });
      assert.equal(r2.status, 500);
      const h = await api.req('GET', '/api/health');
      assert.equal(h.status, 200);
      const st = await api.req('GET', '/api/status');
      assert.equal(st.status, 200);
      assert.equal(st.body.lang, 'en');
      assert.deepEqual(fs.readdirSync(dir), []); // no stray tmp files
    } finally {
      await api.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('language and shortcut are persisted and reported', async () => {
    const api = await startController();
    try {
      assert.equal((await api.req('POST', '/api/language', { body: { lang: 'tr' } })).status, 200);
      assert.equal((await api.req('POST', '/api/language', { body: { lang: 'xx' } })).status, 400);
      assert.equal((await api.req('POST', '/api/shortcut', { body: { shortcut: 'Cmd+L', keyCode: 37, modifiers: 256 } })).status, 200);
      const st = await api.status();
      assert.equal(st.lang, 'tr');
      assert.equal(st.shortcut, 'Cmd+L');
      assert.equal(st.shortcutKeyCode, 37);
      assert.equal(st.shortcutModifiers, 256);
    } finally {
      await api.close();
    }
  });
});

describe('set_scene', () => {
  test('reaches the bulb with exact params and updates status props', async () => {
    await withSetup(async ({ api, bulb }) => {
      await api.connect(bulb.port);
      await waitFor(async () => (await api.status()).props.bright === '42', { message: 'initial props' });
      bulb.props.power = 'off';

      let r = await api.command('set_scene', ['ct', '2700', 30]);
      assert.equal(r.status, 200);
      let st = await api.status();
      assert.equal(st.props.power, 'on');
      assert.equal(st.props.bright, '30');
      assert.equal(st.props.ct, '2700');
      assert.equal(st.props.color_mode, '2');
      await waitFor(() => bulb.commands('set_scene').length === 1, { message: 'ct scene delivered' });
      assert.deepEqual(bulb.commands('set_scene')[0].params, ['ct', 2700, 30]);

      r = await api.command('set_scene', ['hsv', 200, 70, 90]);
      assert.equal(r.status, 200);
      st = await api.status();
      assert.equal(st.props.power, 'on');
      assert.equal(st.props.bright, '90');
      assert.equal(st.props.hue, '200');
      assert.equal(st.props.sat, '70');
      assert.equal(st.props.color_mode, '3');
      assert.equal(st.props.ct, '2700');
      await waitFor(() => bulb.commands('set_scene').length === 2, { message: 'hsv scene delivered' });
      assert.deepEqual(bulb.commands('set_scene')[1].params, ['hsv', 200, 70, 90]);

      const bad = await api.command('set_scene', ['ct', 2700, 30, 'smooth', 500]);
      assert.equal(bad.status, 400);
      assert.equal(bad.body.error, 'invalid scene');
    });
  });

  test('a queued scene drops still-queued set_bright/set_ct_abx/set_hsv/set_power', async () => {
    await withSetup(async ({ api, bulb }) => {
      await api.connect(bulb.port);
      await waitFor(() => bulb.commands('get_prop').length === 1, { message: 'initial get_prop' });
      // Exhaust the burst so the following commands stay queued.
      for (let v = 1; v <= 20; v++) await api.command('set_bright', [v]);
      await sleep(30);
      const brightBefore = bulb.commands('set_bright').length;
      await api.command('set_ct_abx', [3000]);
      await api.command('set_hsv', [10, 20]);
      await api.command('set_power', ['off']);
      await api.command('set_bright', [77]);
      assert.equal((await api.command('set_scene', ['ct', 4000, 60])).status, 200);
      assert.equal(api.ctrl.state.queued, 1, 'only the scene remains queued');
      // Queuing after a scene is fine (normal latest-wins per method).
      await api.command('set_bright', [55]);
      assert.equal(api.ctrl.state.queued, 2);

      await waitFor(() => bulb.commands('set_bright').some((m) => m.params[0] === 55), { timeout: 4000, message: 'post-scene set_bright' });
      assert.deepEqual(bulb.commands('set_scene').map((m) => m.params), [['ct', 4000, 60]]);
      assert.equal(bulb.commands('set_ct_abx').length, 0);
      assert.equal(bulb.commands('set_hsv').length, 0);
      assert.equal(bulb.commands('set_power').length, 0);
      assert.ok(!bulb.commands('set_bright').some((m) => m.params[0] === 77), 'superseded set_bright never sent');
      assert.equal(bulb.commands('set_bright').length, brightBefore + 1);
      const order = nonPropCommands(bulb).slice(-2).map((m) => m.method);
      assert.deepEqual(order, ['set_scene', 'set_bright']);
    });
  });
});

describe('favorites', () => {
  const fav = (o = {}) => Object.assign({ name: 'Read', mode: 'ct', bright: 80, ct: 4000 }, o);
  const post = (api, favorites) => api.req('POST', '/api/favorites', { body: { favorites } });
  const readCfg = (api) => JSON.parse(fs.readFileSync(api.configPath, 'utf8'));

  test('status.favorites is null when never saved', async () => {
    const api = await startController();
    try {
      assert.equal((await api.status()).favorites, null);
      await api.req('POST', '/api/language', { body: { lang: 'de' } });
      assert.equal((await api.status()).favorites, null);
      assert.ok(!('favorites' in readCfg(api)), 'no invented defaults in config');
    } finally {
      await api.close();
    }
  });

  test('valid list round-trips sanitized', async () => {
    const api = await startController();
    try {
      const r = await post(api, [
        fav({ name: '  Read  ', extra: true, hue: 5 }),
        { name: 'Sunset', mode: 'hsv', bright: '40', hue: 20, sat: 90, ct: 2700, icon: 'x' }
      ]);
      const expected = [
        { name: 'Read', mode: 'ct', bright: 80, ct: 4000 },
        { name: 'Sunset', mode: 'hsv', bright: 40, hue: 20, sat: 90 }
      ];
      assert.equal(r.status, 200);
      assert.deepEqual(r.body, { ok: true, favorites: expected });
      assert.deepEqual((await api.status()).favorites, expected);
      assert.deepEqual(readCfg(api).favorites, expected);
    } finally {
      await api.close();
    }
  });

  test('invalid lists are rejected and leave the stored list alone', async () => {
    const api = await startController();
    try {
      assert.equal((await post(api, [fav()])).status, 200);
      for (const bad of [
        Array.from({ length: 13 }, () => fav()),
        [fav({ mode: 'rgb' })],
        [fav({ ct: undefined })],
        [fav({ name: 'x'.repeat(25) })],
        [fav({ name: '   ' })],
        'nope',
        undefined
      ]) {
        const r = await post(api, bad);
        assert.equal(r.status, 400, JSON.stringify(bad));
        assert.equal(r.body.error, 'invalid favorites');
      }
      assert.deepEqual((await api.status()).favorites, [fav()]);
    } finally {
      await api.close();
    }
  });

  test('[] is stored as [] (not null)', async () => {
    const api = await startController();
    try {
      assert.equal((await post(api, [fav()])).status, 200);
      const r = await post(api, []);
      assert.equal(r.status, 200);
      assert.deepEqual(r.body.favorites, []);
      assert.deepEqual((await api.status()).favorites, []);
      assert.deepEqual(readCfg(api).favorites, []);
    } finally {
      await api.close();
    }
  });

  test('save failure -> 500', async () => {
    const { tmpDir } = require('./helpers.js');
    const dir = tmpDir();
    const api = await startController({ configPath: path.join(dir, 'missing', 'config.json') });
    try {
      const r = await post(api, [fav()]);
      assert.equal(r.status, 500);
      assert.equal(r.body.error, 'could not save settings');
    } finally {
      await api.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('favorites survive language, shortcut and connect writes', async () => {
    await withSetup(async ({ api, bulb }) => {
      const list = [fav(), { name: 'Blue', mode: 'hsv', bright: 30, hue: 240, sat: 100 }];
      assert.equal((await post(api, list)).status, 200);
      assert.equal((await api.req('POST', '/api/language', { body: { lang: 'tr' } })).status, 200);
      assert.equal((await api.req('POST', '/api/shortcut', { body: { shortcut: 'Cmd+L', keyCode: 37, modifiers: 256 } })).status, 200);
      assert.equal((await api.connect(bulb.port)).status, 200);
      const cfg = readCfg(api);
      assert.equal(cfg.port, bulb.port);
      assert.equal(cfg.lang, 'tr');
      assert.deepEqual(cfg.favorites, list);
      const st = await api.status();
      assert.equal(st.lang, 'tr');
      assert.deepEqual(st.favorites, list);
    });
  });
});

describe('probeYeelight', () => {
  test('true against fake bulb', async () => {
    const bulb = new FakeBulb();
    await bulb.start();
    try {
      assert.equal(await probeYeelight('127.0.0.1', 1000, bulb.port), true);
    } finally {
      await bulb.stop();
    }
  });

  test('false against a TCP server that never answers', async () => {
    const sockets = new Set();
    const silent = net.createServer((s) => { sockets.add(s); s.on('error', () => {}); });
    await new Promise((r) => silent.listen(0, '127.0.0.1', r));
    try {
      const t0 = Date.now();
      assert.equal(await probeYeelight('127.0.0.1', 200, silent.address().port), false);
      assert.ok(Date.now() - t0 < 1000);
    } finally {
      for (const s of sockets) s.destroy();
      await new Promise((r) => silent.close(r));
    }
  });

  test('false against a closed port', async () => {
    assert.equal(await probeYeelight('127.0.0.1', 300, await freePort()), false);
  });
});

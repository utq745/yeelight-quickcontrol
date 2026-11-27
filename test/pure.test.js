'use strict';

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const { validateCommand, sanitizeFavorites, hostsForInterface } = require('../server.js');

describe('validateCommand', () => {
  const ok = (m, p) => {
    const r = validateCommand(m, p);
    assert.ok(!r.error, `expected ${m} ${JSON.stringify(p)} to be valid, got ${r.error}`);
    return r.params;
  };
  const bad = (m, p) => {
    const r = validateCommand(m, p);
    assert.ok(r.error, `expected ${m} ${JSON.stringify(p)} to be rejected`);
    assert.equal(r.params, undefined);
  };

  test('rejects unknown methods and non-array params', () => {
    bad('get_prop', ['power']);
    bad('set_scene', []);
    bad(undefined, []);
    bad('set_power', 'on');
    bad('set_power', null);
  });

  test('set_power accepts on/off only', () => {
    assert.deepEqual(ok('set_power', ['on']), ['on']);
    assert.deepEqual(ok('set_power', ['off']), ['off']);
    bad('set_power', ['ON']);
    bad('set_power', ['toggle']);
    bad('set_power', [1]);
    bad('set_power', []);
  });

  test('set_bright range 1..100', () => {
    bad('set_bright', [0]);
    assert.deepEqual(ok('set_bright', [1]), [1]);
    assert.deepEqual(ok('set_bright', [100]), [100]);
    bad('set_bright', [101]);
    bad('set_bright', [-5]);
  });

  test('set_bright rejects non-integers and non-numerics', () => {
    bad('set_bright', [50.5]);
    bad('set_bright', ['50.5']);
    bad('set_bright', ['abc']);
    bad('set_bright', ['']);
    bad('set_bright', ['   ']);
    bad('set_bright', [true]);
    bad('set_bright', [null]);
    bad('set_bright', [NaN]);
    bad('set_bright', []);
  });

  test('string numerics are coerced to numbers', () => {
    assert.deepEqual(ok('set_bright', ['50']), [50]);
    assert.deepEqual(ok('set_hsv', ['200', '30']), [200, 30]);
    assert.deepEqual(ok('set_ct_abx', ['2700']), [2700]);
    assert.deepEqual(ok('set_bright', ['50', 'smooth', '500']), [50, 'smooth', 500]);
    for (const v of ok('set_hsv', ['10', '20', 'sudden', '30'])) {
      if (v !== 'sudden') assert.equal(typeof v, 'number');
    }
  });

  test('set_hsv hue 0..359, sat 0..100', () => {
    assert.deepEqual(ok('set_hsv', [0, 0]), [0, 0]);
    assert.deepEqual(ok('set_hsv', [359, 100]), [359, 100]);
    bad('set_hsv', [360, 50]);
    bad('set_hsv', [-1, 50]);
    bad('set_hsv', [100, 101]);
    bad('set_hsv', [100, -1]);
    bad('set_hsv', [100]);
  });

  test('set_ct_abx range 1700..6500', () => {
    assert.deepEqual(ok('set_ct_abx', [1700]), [1700]);
    assert.deepEqual(ok('set_ct_abx', [6500]), [6500]);
    bad('set_ct_abx', [1699]);
    bad('set_ct_abx', [6501]);
  });

  test('transition effect/duration validation', () => {
    assert.deepEqual(ok('set_power', ['on', 'smooth']), ['on', 'smooth']);
    assert.deepEqual(ok('set_power', ['on', 'sudden', 30]), ['on', 'sudden', 30]);
    assert.deepEqual(ok('set_power', ['on', 'smooth', 10000]), ['on', 'smooth', 10000]);
    bad('set_power', ['on', 'smooth', 29]);
    bad('set_power', ['on', 'smooth', 10001]);
    bad('set_power', ['on', 'smooth', 500.5]);
    bad('set_power', ['on', 'smooth', 'fast']);
    bad('set_power', ['on', 'fade', 500]);
    bad('set_power', ['on', 500]);
    bad('set_ct_abx', [3000, 'linear']);
  });

  test('too many params is rejected', () => {
    bad('set_power', ['on', 'smooth', 500, 1]);
    bad('set_bright', [50, 'smooth', 500, 'extra']);
    bad('set_hsv', [10, 20, 'smooth', 500, 0]);
  });
});

describe('set_scene validation', () => {
  const ok = (p) => {
    const r = validateCommand('set_scene', p);
    assert.ok(!r.error, `expected ${JSON.stringify(p)} to be valid, got ${r.error}`);
    return r.params;
  };
  const bad = (p) => {
    const r = validateCommand('set_scene', p);
    assert.equal(r.error, 'invalid scene', `expected ${JSON.stringify(p)} to be rejected`);
    assert.equal(r.params, undefined);
  };

  test('valid ct and hsv scenes, numeric strings coerced', () => {
    assert.deepEqual(ok(['ct', 1700, 1]), ['ct', 1700, 1]);
    assert.deepEqual(ok(['ct', 6500, 100]), ['ct', 6500, 100]);
    assert.deepEqual(ok(['hsv', 0, 0, 1]), ['hsv', 0, 0, 1]);
    assert.deepEqual(ok(['hsv', 359, 100, 100]), ['hsv', 359, 100, 100]);
    assert.deepEqual(ok(['ct', '2700', '50']), ['ct', 2700, 50]);
    assert.deepEqual(ok(['hsv', '200', '30', '40']), ['hsv', 200, 30, 40]);
  });

  test('wrong mode', () => {
    bad(['color', 16711680, 50]);
    bad(['cf', 0, 0, '']);
    bad(['CT', 2700, 50]);
    bad([2700, 50]);
    bad([]);
  });

  test('out of range', () => {
    bad(['ct', 1699, 50]);
    bad(['ct', 6501, 50]);
    bad(['ct', 2700, 0]);
    bad(['ct', 2700, 101]);
    bad(['hsv', 360, 50, 50]);
    bad(['hsv', -1, 50, 50]);
    bad(['hsv', 10, 101, 50]);
    bad(['hsv', 10, 50, 0]);
    bad(['hsv', 10, 50, 101]);
  });

  test('wrong length (no transition params)', () => {
    bad(['ct', 2700]);
    bad(['ct', 2700, 50, 'smooth']);
    bad(['ct', 2700, 50, 'smooth', 500]);
    bad(['hsv', 10, 50]);
    bad(['hsv', 10, 50, 50, 'smooth']);
  });

  test('bools, fractions and non-numerics rejected', () => {
    bad(['ct', true, 50]);
    bad(['ct', 2700, true]);
    bad(['hsv', 10, false, 50]);
    bad(['ct', 2700.5, 50]);
    bad(['hsv', 10, 50, '50.5']);
    bad(['ct', null, 50]);
    bad(['ct', '', 50]);
  });
});

describe('sanitizeFavorites', () => {
  const ct = (o = {}) => Object.assign({ name: 'Read', mode: 'ct', bright: 80, ct: 4000 }, o);
  const hsv = (o = {}) => Object.assign({ name: 'Red', mode: 'hsv', bright: 50, hue: 0, sat: 100 }, o);

  test('valid list is sanitized', () => {
    const out = sanitizeFavorites([
      ct({ name: '  Read  ', extra: 1, hue: 10, sat: 20 }),
      hsv({ ct: 3000, color: 'red', bright: '50' })
    ]);
    assert.deepEqual(out, [
      { name: 'Read', mode: 'ct', bright: 80, ct: 4000 },
      { name: 'Red', mode: 'hsv', bright: 50, hue: 0, sat: 100 }
    ]);
  });

  test('empty list and 12 items are valid, 13 is not', () => {
    assert.deepEqual(sanitizeFavorites([]), []);
    assert.equal(sanitizeFavorites(Array.from({ length: 12 }, () => ct())).length, 12);
    assert.equal(sanitizeFavorites(Array.from({ length: 13 }, () => ct())), null);
  });

  test('name rules: trimmed length 1..24', () => {
    assert.equal(sanitizeFavorites([ct({ name: 'x'.repeat(24) })])[0].name.length, 24);
    assert.equal(sanitizeFavorites([ct({ name: `  ${'x'.repeat(24)}  ` })])[0].name.length, 24);
    assert.equal(sanitizeFavorites([ct({ name: 'x'.repeat(25) })]), null);
    assert.equal(sanitizeFavorites([ct({ name: '' })]), null);
    assert.equal(sanitizeFavorites([ct({ name: '   ' })]), null);
    assert.equal(sanitizeFavorites([ct({ name: 5 })]), null);
    assert.equal(sanitizeFavorites([ct({ name: undefined })]), null);
    // 24 emoji count as 24 characters, not 48 UTF-16 units
    assert.ok(sanitizeFavorites([ct({ name: '💡'.repeat(24) })]));
  });

  test('invalid items rejected', () => {
    for (const bad of [
      null, 'x', {}, { favorites: [] },
      [null], [[1, 2]], ['Read'],
      [ct({ mode: 'rgb' })], [ct({ mode: undefined })],
      [ct({ ct: undefined })], [ct({ ct: 1699 })], [ct({ ct: 6501 })], [ct({ ct: true })],
      [ct({ bright: 0 })], [ct({ bright: 101 })], [ct({ bright: 50.5 })], [ct({ bright: undefined })],
      [hsv({ hue: undefined })], [hsv({ sat: undefined })], [hsv({ hue: 360 })], [hsv({ sat: 101 })],
      [ct(), ct({ ct: 100 })]
    ]) {
      assert.equal(sanitizeFavorites(bad), null, JSON.stringify(bad));
    }
  });
});

describe('hostsForInterface', () => {
  test('/24 excludes self, network and broadcast (253 hosts)', () => {
    const hosts = hostsForInterface('192.168.1.10', '255.255.255.0');
    assert.equal(hosts.length, 253);
    assert.ok(!hosts.includes('192.168.1.10'));
    assert.ok(!hosts.includes('192.168.1.0'));
    assert.ok(!hosts.includes('192.168.1.255'));
    assert.equal(hosts[0], '192.168.1.1');
    assert.equal(hosts[hosts.length - 1], '192.168.1.254');
  });

  test('/16 is narrowed to the interface /24', () => {
    const hosts = hostsForInterface('10.0.5.7', '255.255.0.0');
    assert.equal(hosts.length, 253);
    assert.ok(hosts.every((h) => h.startsWith('10.0.5.')));
    assert.ok(!hosts.includes('10.0.5.7'));
  });

  test('/30 gives exactly 1 host', () => {
    assert.deepEqual(hostsForInterface('192.168.1.1', '255.255.255.252'), ['192.168.1.2']);
  });

  test('missing netmask defaults to /24', () => {
    assert.equal(hostsForInterface('172.16.3.4').length, 253);
  });
});

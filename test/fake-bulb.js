'use strict';

/**
 * Minimal fake Yeelight bulb speaking the LAN protocol (JSON lines, "\r\n").
 *
 *   const bulb = new FakeBulb();
 *   await bulb.start();          // random port, bulb.port holds it
 *   bulb.received                // [{ id, method, params }] in arrival order
 *   bulb.pushProps({ power: 'on' })
 *   bulb.dropClients()           // destroy all client sockets, keep listening
 *   await bulb.stop()            // stop listening + drop clients
 *   await bulb.start(bulb.port)  // restart on the same port
 *
 * `replyIds(msg)` may be overridden to send replies for non-get_prop commands
 * under different ids (used to provoke id collisions).
 */

const net = require('net');

class FakeBulb {
  constructor(options = {}) {
    this.props = Object.assign({
      power: 'on', bright: '42', ct: '3500', rgb: '255', hue: '120', sat: '80', color_mode: '2'
    }, options.props);
    this.replyIds = options.replyIds || ((msg) => [msg.id]);
    this.received = [];
    this.sockets = new Set();
    this.connectionCount = 0;
    this.server = null;
    this.port = null;
  }

  start(port = 0) {
    return new Promise((resolve, reject) => {
      const server = net.createServer((sock) => this._onConnection(sock));
      server.once('error', reject);
      server.listen(port, '127.0.0.1', () => {
        server.off('error', reject);
        this.server = server;
        this.port = server.address().port;
        resolve(this.port);
      });
    });
  }

  _onConnection(sock) {
    this.connectionCount++;
    this.sockets.add(sock);
    sock.on('close', () => this.sockets.delete(sock));
    sock.on('error', () => {});
    let buf = '';
    sock.on('data', (d) => {
      buf += d.toString('utf8');
      const lines = buf.split('\r\n');
      buf = lines.pop();
      for (const line of lines) {
        if (!line) continue;
        let msg;
        try { msg = JSON.parse(line); } catch (e) { continue; }
        this.received.push(msg);
        this._reply(sock, msg);
      }
    });
  }

  _reply(sock, msg) {
    if (msg.method === 'get_prop') {
      const result = (msg.params || []).map((k) => (k in this.props ? this.props[k] : ''));
      this._send(sock, { id: msg.id, result });
      return;
    }
    for (const id of this.replyIds(msg)) this._send(sock, { id, result: ['ok'] });
  }

  _send(sock, obj) {
    if (!sock.destroyed) sock.write(JSON.stringify(obj) + '\r\n');
  }

  /** Sends a {"method":"props"} notification to every connected client. */
  pushProps(params) {
    Object.assign(this.props, params);
    for (const s of this.sockets) this._send(s, { method: 'props', params });
  }

  commands(method) {
    return this.received.filter((m) => !method || m.method === method);
  }

  dropClients() {
    for (const s of this.sockets) s.destroy();
    this.sockets.clear();
  }

  stop() {
    this.dropClients();
    const server = this.server;
    this.server = null;
    if (!server) return Promise.resolve();
    return new Promise((resolve) => server.close(() => resolve()));
  }
}

module.exports = { FakeBulb };

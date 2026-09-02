// Minimal dependency-free Source RCON client for Factorio.
// usage: node rcon.js <host> <port> <password> <command...>
const net = require('net');

const [host, port, password, ...cmdParts] = process.argv.slice(2);
const command = cmdParts.join(' ');
if (!command) {
  console.error('usage: node rcon.js <host> <port> <password> <command...>');
  process.exit(64);
}

const AUTH = 3;
const EXEC = 2;
const RESPONSE_VALUE = 0;
const AUTH_RESPONSE = 2;

function pkt(id, type, body) {
  const b = Buffer.from(body, 'utf8');
  const buf = Buffer.alloc(12 + b.length + 2);
  buf.writeInt32LE(b.length + 10, 0);
  buf.writeInt32LE(id, 4);
  buf.writeInt32LE(type, 8);
  b.copy(buf, 12);
  buf.writeInt16LE(0, 12 + b.length);
  return buf;
}

const sock = new net.Socket();
sock.setTimeout(30000);

let acc = Buffer.alloc(0);
let authed = false;
const replies = [];

// Factorio sends no end-of-reply sentinel, so settle on a quiet period.
let quiet = null;
function settle() {
  clearTimeout(quiet);
  quiet = setTimeout(() => {
    const body = replies.filter((r) => r.trim()).pop() ?? '';
    process.stdout.write(body);
    sock.destroy();
    process.exit(0);
  }, 400);
}

sock.on('error', (e) => { console.error('ERR ' + e.message); process.exit(2); });
sock.on('timeout', () => { console.error('ERR timeout'); process.exit(3); });

sock.connect(parseInt(port, 10), host, () => sock.write(pkt(1, AUTH, password)));

sock.on('data', (d) => {
  acc = Buffer.concat([acc, d]);
  while (acc.length >= 4) {
    const size = acc.readInt32LE(0);
    if (acc.length < size + 4) break;
    const id = acc.readInt32LE(4);
    const type = acc.readInt32LE(8);
    const body = acc.slice(12, 4 + size - 2).toString('utf8');
    acc = acc.slice(4 + size);

    if (!authed) {
      if (id === -1) { console.error('ERR auth failed'); process.exit(4); }
      if (type === AUTH_RESPONSE) {
        authed = true;
        // The first Lua console command in a session answers with
        // "Please repeat the command to proceed", so always send it twice.
        sock.write(pkt(2, EXEC, command));
        sock.write(pkt(4, EXEC, command));
        settle();
      }
    } else if (type === RESPONSE_VALUE) {
      if (body) replies.push(body);
      settle();
    }
  }
});

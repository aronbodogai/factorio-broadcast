// Diagnostic: print every datagram the mod emits, without interpreting it.
// usage: node scripts/udp-tap.js [port] [seconds]
const dgram = require('dgram');

const PORT = Number(process.argv[2] || 41234);
const SECONDS = Number(process.argv[3] || 6);

const sock = dgram.createSocket('udp4');
let n = 0;

sock.on('message', (msg) => {
  n++;
  let kind = '?';
  let name = '-';
  try {
    const parsed = JSON.parse(msg.toString('utf8'));
    kind = parsed.k;
    name = parsed.name || '-';
  } catch {
    kind = 'PARSE_FAIL';
  }
  console.log(msg.length + 'B k=' + kind + ' name=' + name);
});

sock.on('error', (err) => {
  console.error('bind failed: ' + err.message);
  process.exit(1);
});

sock.bind(PORT, '127.0.0.1', () => console.log('tap listening on 127.0.0.1:' + PORT));
setTimeout(() => {
  console.log('total ' + n + ' datagrams in ' + SECONDS + 's');
  process.exit(0);
}, SECONDS * 1000);

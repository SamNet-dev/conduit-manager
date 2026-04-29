#!/usr/bin/env node
// Conduit Dashboard API Server
// Runs on 0.0.0.0:3456 — serves the dashboard + API endpoints
//
// Requirements:
//   • Node.js (no npm packages — stdlib only)
//   • Must be run as root OR as a user in the `docker` group
//     (docker commands and reading /opt/conduit data files need access)
//   • The `conduit` CLI must be installed at /usr/local/bin/conduit

const http   = require('http');
const { exec, execSync } = require('child_process');
const fs     = require('fs');
const path   = require('path');
const os     = require('os');
const { URL } = require('url');

const PORT        = process.env.DASHBOARD_PORT  || 3456;
const INSTALL_DIR = process.env.CONDUIT_DIR     || '/opt/conduit';
const CONDUIT_BIN = process.env.CONDUIT_BIN     || '/usr/local/bin/conduit';

// ── Startup checks ────────────────────────────────────────────────────────────

function checkPrereqs() {
  if (process.getuid && process.getuid() !== 0) {
    try {
      const groups = execSync('id -Gn', { encoding: 'utf8' }).trim().split(/\s+/);
      if (!groups.includes('docker')) {
        console.warn('⚠  Not running as root and not in the docker group.');
        console.warn('   Docker commands may fail. Re-run as root or add your user to the docker group:');
        console.warn('   sudo usermod -aG docker $USER && newgrp docker');
      }
    } catch (_) { /* ignore */ }
  }
  if (!fs.existsSync(CONDUIT_BIN)) {
    console.warn(`⚠  conduit CLI not found at ${CONDUIT_BIN}. Some endpoints will not work.`);
  }
}

// ── LAN IP detection ─────────────────────────────────────────────────────────

function getLanIp() {
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const iface of ifaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal) return iface.address;
    }
  }
  return 'your-server-ip';
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function stripAnsi(s) {
  return (s || '')
    .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '')
    .replace(/[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f]/g, '');
}

function runCmd(cmd, timeoutMs = 30000) {
  return new Promise(resolve => {
    exec(cmd, { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ out: stdout || '', err: stderr || '', code: err?.code ?? 0 });
    });
  });
}

const cache = {};

function getCached(key, ttlMs, fn) {
  const now = Date.now();
  if (cache[key] && (now - cache[key].ts) < ttlMs) {
    return Promise.resolve({ ...cache[key].data, _cached: true, _age: Math.round((now - cache[key].ts) / 1000) });
  }
  return fn().then(data => {
    cache[key] = { data, ts: now };
    return { ...data, _cached: false, _age: 0 };
  });
}

function invalidate(key) { delete cache[key]; }

// ── Parsers ───────────────────────────────────────────────────────────────────

// Parse /opt/conduit/traffic_stats/cumulative_data
// Format per line: country|from_bytes|to_bytes
function parsePeerFile(filePath) {
  const result = { inbound: [], outbound: [] };
  if (!fs.existsSync(filePath)) return result;

  const raw = fs.readFileSync(filePath, 'utf8');
  const inbound  = [];
  const outbound = [];

  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const parts = t.split('|');
    if (parts.length < 3) continue;
    const country   = parts[0].trim();
    const fromBytes = parseInt(parts[1]) || 0;
    const toBytes   = parseInt(parts[2]) || 0;
    if (!country || country.includes('error') || country.includes("can't")) continue;
    if (fromBytes > 0) inbound.push({ country, bytes: fromBytes });
    if (toBytes   > 0) outbound.push({ country, bytes: toBytes  });
  }

  inbound.sort((a, b)  => b.bytes - a.bytes);
  outbound.sort((a, b) => b.bytes - a.bytes);

  result.inbound  = inbound.slice(0, 10).map(e => ({ country: e.country, total: formatBytes(e.bytes), bytes: e.bytes }));
  result.outbound = outbound.slice(0, 10).map(e => ({ country: e.country, total: formatBytes(e.bytes), bytes: e.bytes }));
  result.lastUpdate = new Date().toISOString();
  return result;
}

function formatBytes(b) {
  if (b >= 1099511627776) return (b / 1099511627776).toFixed(2) + ' TB';
  if (b >= 1073741824)    return (b / 1073741824).toFixed(2)    + ' GB';
  if (b >= 1048576)       return (b / 1048576).toFixed(2)       + ' MB';
  if (b >= 1024)          return (b / 1024).toFixed(2)          + ' KB';
  return b + ' B';
}

function parseHealth(raw) {
  const lines  = stripAnsi(raw).split('\n');
  const checks = [];
  let container = 'Node';
  let allPassed = false;

  for (const line of lines) {
    const t = line.trim();
    if (!t) continue;
    if (/^-{3,}/.test(t) && t.endsWith('---')) {
      container = t.replace(/^-+\s*|\s*-+$/g, '').trim();
      continue;
    }
    if (t.includes('HEALTH CHECK') || t.startsWith('===')) continue;
    if (t.includes('All health checks passed') || t.startsWith('✓')) { allPassed = true; continue; }

    const m = t.match(/^(.+?):\s{2,}(.+)$/);
    if (m) {
      const label  = m[1].trim();
      const val    = m[2].trim();
      const isOk   = val.startsWith('OK') || val.startsWith('✓');
      const isFail = val.startsWith('FAIL') || val.startsWith('✗');
      checks.push({ container, label, status: isOk ? 'OK' : isFail ? 'FAIL' : 'INFO', detail: val });
    }
  }
  return { checks, allPassed };
}

// ── API Definitions ───────────────────────────────────────────────────────────

const API = {

  // status --json: clean JSON output, works non-interactively
  status: {
    ttl: 30000,
    fn: async () => {
      const { out, err } = await runCmd(`${CONDUIT_BIN} status --json`);
      const text = out.trim();
      if (!text) throw new Error(err || 'Empty response from conduit status --json');
      return JSON.parse(text);
    },
  },

  // peers: read tracker data files directly — no TUI, instant response
  peers: {
    ttl: 30000,
    fn: async () => {
      const cumFile  = path.join(INSTALL_DIR, 'traffic_stats', 'cumulative_data');
      const snapFile = path.join(INSTALL_DIR, 'traffic_stats', 'tracker_snapshot');
      // Prefer snapshot (recent window) but fall back to cumulative
      const fileToUse = fs.existsSync(snapFile) ? snapFile : cumFile;
      if (!fs.existsSync(fileToUse)) {
        return { inbound: [], outbound: [], lastUpdate: null, note: 'Tracker data not yet available' };
      }
      return parsePeerFile(fileToUse);
    },
  },

  // health: non-interactive, prints and exits
  health: {
    ttl: 60000,
    fn: async () => {
      const { out } = await runCmd(`${CONDUIT_BIN} health 2>&1`, 20000);
      return parseHealth(out);
    },
  },

  // logs: read directly from docker — no interactive container selector
  logs: {
    ttl: 15000,
    fn: async () => {
      const { out: nameOut } = await runCmd(
        `docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^conduit(-[0-9]+)?$'`,
        5000,
      );
      const names = nameOut.trim().split('\n').filter(Boolean);
      if (names.length === 0) return { lines: ['No running conduit containers found.'] };

      const allLines = [];
      for (const name of names) {
        const { out } = await runCmd(`docker logs --tail 80 ${name} 2>&1`, 10000);
        const prefix = names.length > 1 ? `[${name}] ` : '';
        stripAnsi(out).split('\n')
          .filter(l => l.trim())
          .forEach(l => allLines.push(prefix + l));
      }
      return { lines: allLines.slice(-150) };
    },
  },

  // iran-status: fetches from external API, non-interactive
  'iran-status': {
    ttl: 120000,
    fn: async () => {
      const { out } = await runCmd(`${CONDUIT_BIN} iran-status 2>&1`, 35000);
      const clean  = stripAnsi(out);
      const bgpM   = clean.match(/(\d+)%\s+BGP reachability/);
      return {
        raw:             clean,
        bgpReachability: bgpM ? parseInt(bgpM[1]) : null,
        noOutages:       clean.includes('No outages detected'),
        ts:              new Date().toISOString(),
      };
    },
  },

  // iran-test: connectivity test, non-interactive
  'iran-test': {
    ttl: 300000,
    fn: async () => {
      const { out } = await runCmd(`${CONDUIT_BIN} iran-test 2>&1`, 90000);
      return { raw: stripAnsi(out), ts: new Date().toISOString() };
    },
  },

  // containers: direct docker query
  containers: {
    ttl: 30000,
    fn: async () => {
      const { out } = await runCmd(`docker ps -a --format '{{json .}}' 2>&1`);
      const containers = out.trim().split('\n')
        .filter(l => l.trim().startsWith('{'))
        .map(l => { try { return JSON.parse(l); } catch { return null; } })
        .filter(Boolean);
      return { containers };
    },
  },

  // network-stats: non-interactive, fetches from Psiphon API
  'network-stats': {
    ttl: 300000,
    fn: async () => {
      const { out } = await runCmd(`${CONDUIT_BIN} network-stats 2>&1`, 30000);
      return { raw: stripAnsi(out), ts: new Date().toISOString() };
    },
  },

  // conduit-toggle: start/stop the conduit service
  'conduit-toggle': {
    ttl: 0,
    fn: async () => {
      const { out: statusOut } = await runCmd(`${CONDUIT_BIN} status --json`);
      const status  = JSON.parse(statusOut.trim());
      const running = status.status === 'running';
      if (running) {
        await runCmd(`${CONDUIT_BIN} stop`, 30000);
      } else {
        await runCmd(`${CONDUIT_BIN} start`, 30000);
      }
      invalidate('status');
      return { running: !running, ts: new Date().toISOString() };
    },
  },
};

// ── HTTP Server ───────────────────────────────────────────────────────────────

const server = http.createServer(async (req, res) => {
  const parsed   = new URL(req.url, `http://localhost`);
  const pathname = parsed.pathname;

  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');

  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  // Static files
  const staticFiles = {
    '/':           { file: 'index.html', mime: 'text/html; charset=utf-8' },
    '/index.html': { file: 'index.html', mime: 'text/html; charset=utf-8' },
    '/logo.jpg':   { file: 'logo.jpg',   mime: 'image/jpeg' },
    '/logo.png':   { file: 'logo.png',   mime: 'image/png'  },
  };
  if (staticFiles[pathname]) {
    const { file, mime } = staticFiles[pathname];
    fs.readFile(path.join(__dirname, file), (err, data) => {
      if (err) { res.writeHead(404); res.end('Not found'); return; }
      res.writeHead(200, { 'Content-Type': mime });
      res.end(data);
    });
    return;
  }

  res.setHeader('Content-Type', 'application/json');

  const apiMatch = pathname.match(/^\/api\/(.+)$/);
  if (!apiMatch) { res.writeHead(404); res.end(JSON.stringify({ error: 'Not found' })); return; }

  const key = apiMatch[1];
  if (!API[key]) { res.writeHead(404); res.end(JSON.stringify({ error: `Unknown endpoint: ${key}` })); return; }

  // POST forces a cache refresh
  if (req.method === 'POST') invalidate(key);

  try {
    const data = await getCached(key, API[key].ttl, API[key].fn);
    res.writeHead(200);
    res.end(JSON.stringify(data));
  } catch (err) {
    res.writeHead(500);
    res.end(JSON.stringify({ error: err.message }));
  }
});

checkPrereqs();

server.listen(PORT, '0.0.0.0', () => {
  const lan = getLanIp();
  console.log(`🛡️  Conduit Dashboard running`);
  console.log(`   Local → http://localhost:${PORT}`);
  console.log(`   LAN   → http://${lan}:${PORT}`);
  console.log(`   PID: ${process.pid}`);
  console.log(`   CONDUIT_DIR: ${INSTALL_DIR}`);
  console.log(`   CONDUIT_BIN: ${CONDUIT_BIN}`);
});

process.on('SIGTERM', () => { server.close(); process.exit(0); });
process.on('SIGINT',  () => { server.close(); process.exit(0); });

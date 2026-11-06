#!/usr/bin/env python3
"""The Home Board Box before its first use: waits on the home network for the code on the pairing card.

A box is prepared with `install.sh --box`: Docker, InfluxDB's image and the maintenance are on it, but no passwords or
tokens yet. This service stands in on the database's port (8086) until the family enters the card's code in the app:
  GET  /health      what the app's "Zoek op het netwerk" asks every server; answers as a server waiting for its code
  POST /api/claim   {"code": "K7Q4-M2XD"} → 403 wrong code, 429 too many tries, 202 setting up, 200 the pairing code
                    {"code": ..., "done": true} → the app has it: the database takes over the port, this service stops
Only with the right code does the box make its own passwords and tokens (install.sh --claimed), so whoever prepared it
never knew them. The card's code works once: after "done" it is gone. Five wrong codes lock it for 15 minutes.
Run by systemd (homeboard-claim.service). `claim.py new` makes a new code and prints it (for the card).
Standard library only (Debian's python3)."""
import hashlib, hmac, json, os, secrets, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(DIR, 'claim')            # code.hash, fails.json, setup.log; gone once the box is claimed
ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'  # Crockford: no I, L, O, U
LEN, MAX_FAILS, LOCK_S = 8, 5, 15 * 60

def norm(code):
    """K7Q4-m2xd, K7Q4 M2XD → K7Q4M2XD; O→0 and I/L→1 as Crockford reads them"""
    s = ''.join(c for c in str(code).upper() if c.isalnum())
    return s.translate(str.maketrans('OIL', '011'))

def digest(code, salt):
    return hashlib.sha256((salt + ':' + norm(code)).encode()).hexdigest()

def new_code():
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    code = ''.join(secrets.choice(ALPHABET) for _ in range(LEN))
    salt = secrets.token_hex(16)
    with open(os.path.join(STATE, 'code.hash'), 'w') as f: f.write(salt + ' ' + digest(code, salt))
    os.chmod(os.path.join(STATE, 'code.hash'), 0o600)
    try: os.remove(os.path.join(STATE, 'fails.json'))
    except FileNotFoundError: pass
    return code[:4] + '-' + code[4:]

def read_json(name, default):
    try:
        with open(os.path.join(STATE, name)) as f: return json.load(f)
    except Exception: return default

def write_json(name, value):
    with open(os.path.join(STATE, name), 'w') as f: json.dump(value, f)

class Box:
    """the setup in the background, one at a time; state: idle | busy | done | failed"""
    def __init__(self):
        self.lock = threading.Lock()
        self.state = 'done' if os.path.exists(os.path.join(STATE, 'ready')) else 'idle'

    def start(self):
        with self.lock:
            if self.state in ('busy', 'done'): return
            self.state = 'busy'
        threading.Thread(target=self.setup, daemon=True).start()

    def setup(self):
        with open(os.path.join(STATE, 'setup.log'), 'ab') as log:
            ok = subprocess.run([os.path.join(DIR, 'install.sh'), '--claimed'], stdout=log, stderr=subprocess.STDOUT).returncode == 0
        if ok: open(os.path.join(STATE, 'ready'), 'w').close()   # also after a restart of this service
        with self.lock: self.state = 'done' if ok else 'failed'

    def pairing(self):
        out = subprocess.run(['bash', '-c', '. "$1/lib.sh"; pairing_code', '_', DIR], capture_output=True, text=True)
        return out.stdout.strip()

box = Box()
server = None

class Handler(BaseHTTPRequestHandler):
    server_version = 'HomeBoardClaim'
    sys_version = ''

    def log_message(self, *a): pass  # no addresses or codes in the journal

    def send(self, status, body=None):
        data = b'' if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(status)
        if data: self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        if data: self.wfile.write(data)

    def do_GET(self):
        # "influxdb" in name: the app's network search (Android and iOS) only lists what calls itself that; the version
        # says it is this service, so the app asks for the card's code instead of a token
        if self.path in ('/health', '/api/claim'):
            return self.send(200, {'name': 'influxdb', 'status': 'pass', 'version': 'homeboard-claim', 'message': 'Home Board-server wacht op de koppelcode'})
        if self.path == '/ping': return self.send(204)
        self.send(404, {'error': 'not found'})

    def do_POST(self):
        if self.path != '/api/claim': return self.send(404, {'error': 'not found'})
        n = int(self.headers.get('Content-Length') or 0)
        if n > 1024: return self.send(413, {'error': 'too large'})
        try: req = json.loads(self.rfile.read(n) or b'{}')
        except Exception: return self.send(400, {'error': 'json'})
        fails = read_json('fails.json', {'n': 0, 'until': 0})
        now = time.time()
        if fails.get('until', 0) > now: return self.send(429, {'error': 'wait', 's': int(fails['until'] - now) + 1})
        try:
            with open(os.path.join(STATE, 'code.hash')) as f: salt, want = f.read().split()
        except Exception: return self.send(410, {'error': 'claimed'})
        if not hmac.compare_digest(digest(req.get('code', ''), salt), want):
            fails['n'] = fails.get('n', 0) + 1
            if fails['n'] >= MAX_FAILS: fails = {'n': 0, 'until': now + LOCK_S}
            write_json('fails.json', fails)
            return self.send(403, {'error': 'code'})
        write_json('fails.json', {'n': 0, 'until': 0})
        if box.state in ('idle', 'failed'): box.start(); return self.send(202, {'state': 'busy'})
        if box.state == 'busy': return self.send(202, {'state': 'busy'})
        if req.get('done'):
            self.send(200, {'ok': True})
            threading.Thread(target=finish, daemon=True).start()
            return
        code = box.pairing()
        if not code: return self.send(500, {'error': 'setup'})
        self.send(200, code.encode())

def finish():
    """the database takes over port 8086: this service lets go of it first, then a separate unit finishes the job"""
    time.sleep(0.5)
    server.shutdown(); server.server_close()
    subprocess.run(['systemd-run', '--no-block', '--unit=homeboard-claim-done', '--collect', os.path.join(DIR, 'onderhoud.sh'), 'claim-done'])
    os._exit(0)

def main():
    global server
    if sys.argv[1:2] == ['new']:
        print(new_code()); return
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8086
    server = ThreadingHTTPServer(('0.0.0.0', port), Handler)
    server.daemon_threads = True
    server.serve_forever()

if __name__ == '__main__':
    main()

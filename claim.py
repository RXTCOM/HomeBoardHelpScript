#!/usr/bin/env python3
"""The Home Board Box before its first use: waits on the home network for the code on the pairing card.

A box is prepared with `install.sh --box`: Docker, InfluxDB's image and the maintenance are on it, but no passwords or
tokens yet. This service stands in on the database's port (8086) until the family enters the card's code in the app:
  GET  /health      what the app's "Zoek op het netwerk" asks every server; answers as a server waiting for its code
  POST /api/claim   {"code": "K7Q4-M2XD"} → 403 wrong code, 202 setting up, 200 the pairing code
                    (with "login": the family's own login on the server, user homeboard and a fresh password)
                    {"code": ..., "done": true} → the app has it: the database takes over the port, this service stops
Only with the right code does the box make its own passwords and tokens (install.sh --claimed), so whoever prepared it
never knew them. A wrong code costs a second (one try at a time per address), which makes guessing the 8 characters
(32^8 codes) hopeless without locking the family out. The pairing code is handed out until "done", at most 30 minutes
after the first time; then the box finishes by itself and the card's code is gone.
Run by systemd (homeboard-claim.service). `claim.py new` makes a new code and prints it (for the card).
Standard library only (Debian's python3)."""
import hashlib, hmac, json, os, secrets, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(DIR, 'claim')            # code.hash, ready, setup.log; gone once the box is claimed
ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'  # Crockford: no I, L, O, U
LEN, WRONG_DELAY, HANDOUT_S = 8, 1.0, 30 * 60

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
    path = os.path.join(STATE, 'code.hash')
    with open(path + '.tmp', 'w') as f: f.write(salt + ' ' + digest(code, salt)); f.flush(); os.fsync(f.fileno())
    os.chmod(path + '.tmp', 0o600); os.replace(path + '.tmp', path)
    for old in ('ready', 'handout'):
        try: os.remove(os.path.join(STATE, old))
        except FileNotFoundError: pass
    return code[:4] + '-' + code[4:]

def database_on_port():
    """the database already holds port 8086 (the handover was cut off, e.g. by a power cut): nothing left to wait for"""
    out = subprocess.run(['docker', 'port', 'homeboard-influxdb', '8086/tcp'], capture_output=True, text=True)
    return out.returncode == 0 and any(l.strip().startswith(('0.0.0.0:8086', '[::]:8086')) for l in out.stdout.splitlines())

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
finishing = threading.Event()
ip_locks, ip_locks_lock = {}, threading.Lock()

def ip_lock(ip):
    with ip_locks_lock: return ip_locks.setdefault(ip, threading.Lock())

def handout_started():
    """the time the pairing code was first handed out (kept on disk, so a restart doesn't reset the 30 minutes)"""
    p = os.path.join(STATE, 'handout')
    try: return float(open(p).read())
    except Exception:
        t = time.time()
        with open(p, 'w') as f: f.write(str(t))
        return t

class Handler(BaseHTTPRequestHandler):
    server_version = 'HomeBoardClaim'
    sys_version = ''
    timeout = 10   # a client that sends nothing keeps no thread

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
        try: n = int(self.headers.get('Content-Length') or 0)
        except ValueError: return self.send(400, {'error': 'length'})
        if not 0 <= n <= 1024: return self.send(413, {'error': 'too large'})
        try: req = json.loads(self.rfile.read(n) or b'{}')
        except Exception: return self.send(400, {'error': 'json'})
        if not isinstance(req, dict) or not isinstance(req.get('code'), str): return self.send(400, {'error': 'code'})
        if finishing.is_set(): return self.send(410, {'error': 'claimed'})
        try:
            with open(os.path.join(STATE, 'code.hash')) as f: salt, want = f.read().split()
        except Exception: return self.send(410, {'error': 'claimed'})
        # one try at a time per address, and a wrong one costs a second: no lockout that a guest could keep going
        with ip_lock(self.client_address[0]):
            if not hmac.compare_digest(digest(req['code'], salt), want):
                time.sleep(WRONG_DELAY)
                return self.send(403, {'error': 'code'})
        if box.state in ('idle', 'failed'): box.start(); return self.send(202, {'state': 'busy'})
        if box.state == 'busy': return self.send(202, {'state': 'busy'})
        if req.get('done') is True:
            self.send(200, {'ok': True}); finish(); return
        code = box.pairing()
        if not code: return self.send(500, {'error': 'setup'})
        try: out = json.loads(code)
        except Exception: return self.send(500, {'error': 'setup'})
        # the family's own login on the server (install.sh --claimed made its password): shown once in the app
        try:
            with open(os.path.join(STATE, 'login')) as f: out['login'] = json.load(f)
        except Exception: pass
        handout_started()
        self.send(200, json.dumps(out).encode())

def finish():
    """the database takes over port 8086: this service lets go of it, then a unit of its own finishes the job"""
    if finishing.is_set(): return
    finishing.set()
    threading.Thread(target=lambda: (time.sleep(0.5), server.shutdown()), daemon=True).start()

def hand_over():
    """after serve_forever returned: the port is free; a separate unit (it outlives this one) does onderhoud.sh claim-done"""
    unit = 'homeboard-claim-done-%d' % int(time.time())
    return subprocess.run(['systemd-run', '--no-block', '--collect', '--unit=' + unit, os.path.join(DIR, 'onderhoud.sh'), 'claim-done']).returncode == 0

def deadline():
    """the pairing code goes out until "done", at most 30 minutes after the first time: then the box finishes by itself"""
    while not finishing.is_set():
        p = os.path.join(STATE, 'handout')
        if os.path.exists(p) and time.time() - handout_started() > HANDOUT_S: finish()
        time.sleep(20)

def main():
    global server
    if sys.argv[1:2] == ['new']:
        print(new_code()); return
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8086
    if os.path.exists(os.path.join(STATE, 'ready')) and database_on_port():
        hand_over(); return          # cut off halfway: finish the handover, don't fight the database for the port
    threading.Thread(target=deadline, daemon=True).start()
    while True:
        try: server = ThreadingHTTPServer(('0.0.0.0', port), Handler)
        except OSError as e:
            # another program (an earlier database?) holds the port: say so in the journal, systemd tries again later
            print(f'homeboard-claim: poort {port} is bezet ({e}); is er nog een oude installatie?', file=sys.stderr, flush=True)
            time.sleep(30); sys.exit(1)
        server.daemon_threads = True
        server.serve_forever()
        server.server_close()
        if hand_over(): return
        finishing.clear()            # the handover couldn't start: keep the port and keep answering

if __name__ == '__main__':
    main()

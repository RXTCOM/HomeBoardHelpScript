#!/usr/bin/env python3
"""Tests for claim.py (the Home Board Box waiting for its pairing card's code), without root, Docker or systemd:
claim.py runs from a temp folder next to a fake install.sh, lib.sh and onderhoud.sh, with fake docker and systemd-run on
PATH. Run: python3 tests/claim_test.py"""
import json, os, shutil, socket, subprocess, sys, tempfile, threading, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.dirname(HERE)
fails = []
def ok(c, what): print(('  ok   ' if c else '  FOUT ') + what); c or fails.append(what)

def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def setup(systemd_ok=True, docker_port=''):
    d = tempfile.mkdtemp(); shutil.copy(os.path.join(REPO, 'claim.py'), d)
    w = lambda name, text: (open(os.path.join(d, name), 'w').write(text), os.chmod(os.path.join(d, name), 0o755))
    w('install.sh', '#!/bin/bash\nsleep 1; echo "INFLUX_ORG=thuis" > "$(dirname "$0")/.env"\n')
    w('lib.sh', 'pairing_code(){ printf \'{"kb":1,"u":"http://192.168.1.5:8086","o":"thuis","b":"homeboard","t":"TOKEN","r":"board"}\'; }\n')
    w('onderhoud.sh', '#!/bin/bash\necho "$1" >> "$(dirname "$0")/onderhoud.calls"\n')
    b = os.path.join(d, 'bin'); os.mkdir(b)
    w('bin/systemd-run', '#!/bin/bash\n' + ('"${@: -2:1}" "${@: -1}"; exit 0\n' if systemd_ok else 'exit 1\n'))
    w('bin/docker', '#!/bin/bash\n' + (f'echo "{docker_port}"; exit 0\n' if docker_port else 'exit 1\n'))
    code = subprocess.run([sys.executable, os.path.join(d, 'claim.py'), 'new'], capture_output=True, text=True).stdout.strip()
    return d, code

def start(d, port):
    env = {**os.environ, 'PATH': os.path.join(d, 'bin') + ':' + os.environ['PATH']}
    p = subprocess.Popen([sys.executable, os.path.join(d, 'claim.py'), str(port)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for _ in range(50):
        try: socket.create_connection(('127.0.0.1', port), 0.2).close(); return p
        except OSError: time.sleep(0.1)
    return p

def post(port, body, raw=None, headers=None):
    data = raw if raw is not None else json.dumps(body).encode()
    r = urllib.request.Request(f'http://127.0.0.1:{port}/api/claim', data=data, method='POST', headers=headers or {})
    try:
        with urllib.request.urlopen(r, timeout=15) as x: return x.status, x.read().decode()
    except urllib.error.HTTPError as e: return e.code, e.read().decode()
    except Exception as e: return 0, str(e)

def raw_post(port, head):
    s = socket.create_connection(('127.0.0.1', port), 5); s.sendall(head); s.settimeout(5)
    try: return s.recv(200).decode(errors='replace').split(' ')[1]
    except Exception: return '?'
    finally: s.close()

# 1. the whole way: wrong, right (any case, with a dash), setting up, the pairing code, done → handed over, port free
d, code = setup(); port = free_port(); p = start(d, port)
h = json.loads(urllib.request.urlopen(f'http://127.0.0.1:{port}/health').read())
ok(h['name'] == 'influxdb' and h['version'] == 'homeboard-claim', 'health: wacht op de koppelcode')
t = time.time(); s, _ = post(port, {'code': 'ZZZZ-ZZZZ'})
ok(s == 403 and time.time() - t >= 0.9, 'verkeerde code: 403, na een seconde')
s, _ = post(port, {'code': code.lower()}); ok(s == 202, 'juiste code (kleine letters): 202, de server richt zich in')
time.sleep(1.6)
s, body = post(port, {'code': code}); ok(s == 200 and json.loads(body)['t'] == 'TOKEN', 'daarna de koppelcode van het bord')
s, _ = post(port, {'code': code, 'done': True}); ok(s == 200, '"done": 200')
p.wait(10); time.sleep(0.3)
ok(p.returncode == 0 and open(os.path.join(d, 'onderhoud.calls')).read().split() == ['claim-done'], 'dienst gestopt, claim-done aangeroepen')
try: socket.create_connection(('127.0.0.1', port), 0.5).close(); free = False
except OSError: free = True
ok(free, 'poort losgelaten voor de database'); shutil.rmtree(d)

# 2. guessing in parallel: one try at a time per address, a second each; the right code still works (no lockout)
d, code = setup(); port = free_port(); p = start(d, port)
res = []; t = time.time()
th = [threading.Thread(target=lambda: res.append(post(port, {'code': 'ZZZZ-ZZZZ'})[0])) for _ in range(6)]
[x.start() for x in th]; [x.join() for x in th]
ok(res.count(403) == 6 and time.time() - t >= 5.5, f'6 gokken tegelijk: na elkaar, een seconde per stuk ({time.time() - t:.1f} s)')
s, _ = post(port, {'code': code}); ok(s == 202, 'daarna werkt de juiste code gewoon (geen blokkade om te misbruiken)')

# 3. odd input: no crash, a clear status
ok(raw_post(port, b'POST /api/claim HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n') == '413', 'Content-Length -1: 413')
ok(raw_post(port, b'POST /api/claim HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n') == '400', 'Content-Length geen getal: 400')
ok(post(port, None, raw=b'[1,2]')[0] == 400, 'JSON-lijst: 400')
ok(post(port, {'code': 12345678})[0] == 400, 'code geen tekst: 400')
ok(post(port, None, raw=b'x' * 2000)[0] == 413, 'te groot: 413')
ok(p.poll() is None, 'dienst draait nog'); p.terminate(); p.wait(5); shutil.rmtree(d)

# 4. the handover can't start (systemd-run fails): the service keeps the port and keeps answering
d, code = setup(systemd_ok=False); port = free_port(); p = start(d, port)
post(port, {'code': code}); time.sleep(1.6); post(port, {'code': code}); post(port, {'code': code, 'done': True}); time.sleep(1.5)
h = None
try: h = json.loads(urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=3).read())
except Exception: pass
ok(p.poll() is None and h and h['version'] == 'homeboard-claim', 'overdracht mislukt: dienst houdt de poort en antwoordt')
p.terminate(); p.wait(5); shutil.rmtree(d)

# 5. after a power cut halfway: the database already holds 8086 → no fight for the port, the handover finishes
d, code = setup(docker_port='0.0.0.0:8086'); open(os.path.join(d, 'claim', 'ready'), 'w').close(); port = free_port()
p = start(d, port); p.wait(10)
ok(p.returncode == 0 and os.path.exists(os.path.join(d, 'onderhoud.calls')), 'database al op de poort: claim-done opnieuw, dienst stopt')
shutil.rmtree(d)

# 6. the pairing code goes out at most 30 minutes after the first time (deadline shortened for the test)
d, code = setup(); port = free_port()
src = open(os.path.join(d, 'claim.py')).read().replace('8, 1.0, 30 * 60', '8, 1.0, 2').replace('time.sleep(20)', 'time.sleep(0.5)')
open(os.path.join(d, 'claim.py'), 'w').write(src)
p = start(d, port); post(port, {'code': code}); time.sleep(1.6)
s, _ = post(port, {'code': code}); ok(s == 200, 'koppelcode opgehaald')
p.wait(10); ok(p.returncode == 0, 'geen "done": na de deadline rondt de server zelf af')
shutil.rmtree(d)
print('KLAAR' if not fails else f'FOUT: {len(fails)}'); sys.exit(1 if fails else 0)

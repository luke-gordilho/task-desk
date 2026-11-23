#!/usr/bin/env python3
"""Local task tracker. Python standard library only."""
import argparse, json, sqlite3, webbrowser
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
ROOT = Path(__file__).resolve().parent
DB = ROOT / 'tasks.sqlite3'
STATUSES = ('To do', 'In progress', 'Blocked', 'Done')
def connect():
    db = sqlite3.connect(DB, timeout=10)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA foreign_keys=ON')
    return db
def initialize():
    with connect() as db:
        db.execute('PRAGMA journal_mode=WAL')
        db.executescript('''CREATE TABLE IF NOT EXISTS projects (name TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS tasks (
        id INTEGER PRIMARY KEY, title TEXT NOT NULL, project TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'To do', priority TEXT NOT NULL DEFAULT 'Medium',
        owner TEXT NOT NULL DEFAULT 'Luke', due_date TEXT NOT NULL DEFAULT '',
        notes TEXT NOT NULL DEFAULT '', next_action TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
        CREATE INDEX IF NOT EXISTS tasks_project_status ON tasks(project,status);''')
        for p in ROOT.parent.iterdir():
            if p.is_dir() and not p.name.startswith('.') and p != ROOT:
                db.execute('INSERT OR IGNORE INTO projects VALUES (?)', (p.name.strip(),))
class Handler(BaseHTTPRequestHandler):
    def reply(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Cache-Control','no-store'); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/':
            data = (ROOT/'index.html').read_bytes()
            self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.send_header('Cache-Control','no-store'); self.end_headers(); self.wfile.write(data)
        elif path == '/api/tasks':
            with connect() as db:
                self.reply({'tasks':[dict(r) for r in db.execute('SELECT * FROM tasks ORDER BY updated_at DESC,id DESC')], 'projects':[r[0] for r in db.execute('SELECT name FROM projects UNION SELECT project FROM tasks WHERE project != "" ORDER BY 1')]})
        else: self.reply({'error':'Not found'},404)
    def do_POST(self):
        # Browser mutations must originate from this local viewer.
        if self.headers.get('Origin') not in (None, f'http://127.0.0.1:{self.server.server_port}', f'http://localhost:{self.server.server_port}') or self.headers.get('Content-Type','').split(';')[0] != 'application/json':
            return self.reply({'error':'Unsupported request'},403)
        if urlparse(self.path).path != '/api/tasks': return self.reply({'error':'Not found'},404)
        try:
            length=int(self.headers.get('Content-Length',0))
            if not 0 < length <= 100000: raise ValueError('Request too large or empty')
            task=json.loads(self.rfile.read(length))
            fields=('title','project','status','priority','owner','due_date','notes','next_action')
            values=[str(task.get(k,'' )).strip() for k in fields]
            if not values[0]: raise ValueError('A title is required')
            if values[2] not in STATUSES: raise ValueError('Invalid status')
            if values[3] not in ('High','Medium','Low'): raise ValueError('Invalid priority')
            if values[5]:
                from datetime import date
                date.fromisoformat(values[5])
            with connect() as db:
                if task.get('id'):
                    cur=db.execute("UPDATE tasks SET "+','.join(k+'=?' for k in fields)+",updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?",values+[int(task['id'])])
                    if not cur.rowcount: return self.reply({'error':'Task not found'},404)
                    ident=int(task['id'])
                else:
                    ident=db.execute('INSERT INTO tasks ('+','.join(fields)+') VALUES ('+','.join('?' for _ in fields)+')',values).lastrowid
            self.reply({'id':ident})
        except (ValueError,TypeError,json.JSONDecodeError) as e: self.reply({'error':str(e)},400)
    def log_message(self, *args): pass
if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--port',type=int,default=8765); parser.add_argument('--open',action='store_true'); args=parser.parse_args()
    initialize()
    try: server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    except OSError:
        raise SystemExit(f'Port {args.port} is in use. Open the existing tracker or choose another port with --port.')
    url=f'http://127.0.0.1:{args.port}'
    print(f'Task tracker: {url}',flush=True)
    if args.open: webbrowser.open(url)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()

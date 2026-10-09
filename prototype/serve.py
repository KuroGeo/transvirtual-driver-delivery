"""Local-only preview, with a quiet request log and room for map assets."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

class PreviewHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

class PreviewServer(ThreadingHTTPServer):
    request_queue_size=128
    daemon_threads=True

if __name__=='__main__':
    handler=partial(PreviewHandler,directory=str(Path(__file__).resolve().parent))
    with PreviewServer(('127.0.0.1',8764),handler) as server:
        print('Preview ready at http://127.0.0.1:8764',flush=True)
        server.serve_forever()

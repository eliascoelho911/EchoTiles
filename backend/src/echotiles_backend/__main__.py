"""CLI: `serve` inicia a API e um único processo worker supervisionado."""

import argparse
import subprocess
import sys
import threading

import uvicorn

from .api import create_app
from .config import Settings
from .worker import Worker, stop_process_tree


def main():
    parser = argparse.ArgumentParser(description="Biblioteca musical do EchoTiles")
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="Inicia API e worker separado")
    serve.add_argument("--host", default="0.0.0.0")
    serve.add_argument("--port", type=int, default=8765)
    commands.add_parser("worker", help="Executa somente o worker da biblioteca")
    args = parser.parse_args()
    settings = Settings.from_env()
    if args.command == "worker":
        Worker(settings).run_forever()
        return
    server = uvicorn.Server(uvicorn.Config(create_app(settings), host=args.host, port=args.port))
    worker = subprocess.Popen([sys.executable, "-m", "echotiles_backend", "worker"])

    def supervise():
        worker.wait()
        server.should_exit = True

    supervisor = threading.Thread(target=supervise, daemon=True)
    supervisor.start()
    try:
        server.run()
    finally:
        if worker.poll() is None:
            worker.terminate()
            try:
                worker.wait(timeout=5)
            except subprocess.TimeoutExpired:
                stop_process_tree(worker.pid)
                worker.wait()
        supervisor.join(timeout=1)
    if worker.returncode not in {0, -15}:
        raise SystemExit("O worker encerrou antes de concluir o serviço.")


if __name__ == "__main__":
    main()

"""An explicit-FTPS server for FTPSTests, on pyftpdlib with a self-signed certificate.

    python ftps_server.py ROOT CERT KEY PORT USER PASSWORD

Control and data channels both require TLS, as the app's ftpes:// accounts do. Passive ports come from 30000-30099
on 127.0.0.1. Run it through scripts/ci/ftps.sh, which creates the certificate and a virtualenv with pyftpdlib.
"""
import sys

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import TLS_FTPHandler
from pyftpdlib.servers import FTPServer


def main(root, cert, key, port, user, password):
    authorizer = DummyAuthorizer()
    authorizer.add_user(user, password, root, perm="elradfmwMT")
    handler = TLS_FTPHandler
    handler.certfile = cert
    handler.keyfile = key
    handler.authorizer = authorizer
    handler.tls_control_required = True
    handler.tls_data_required = True
    handler.passive_ports = range(30000, 30100)
    handler.masquerade_address = "127.0.0.1"
    server = FTPServer(("127.0.0.1", int(port)), handler)
    server.serve_forever()


if __name__ == "__main__":
    main(*sys.argv[1:7])

#!/usr/bin/env python
"""
Probe a list of discovered Synology NAS (syno_discover.py's JSON output)
to find which ones are running Syno_Toolbox with a reachable api.cgi.
Compatible with Python 2 (DSM 6) and Python 3 (DSM 7).

syno_discover.py finds ANY Synology NAS on the network - this narrows
that down to only ones actually running Syno_Toolbox, for config_backup's
remote-target dropdowns. Read-only, unauthenticated probe (pingtoolbox)
- reveals nothing beyond "this package is installed and reachable here".

Reads the NAS list as JSON on stdin, writes the filtered/annotated list
as JSON to stdout. Each surviving entry gains "toolbox_port" (the
https_port that answered) and "toolbox_hostname" (from the probe
response, may differ from the discovery hostname if it was unset there).

Usage:
    echo '[{"ip":"192.168.20.10","https_port":5001}, ...]' | python probe_toolbox_nas.py
    python probe_toolbox_nas.py --timeout 3
"""

from __future__ import print_function
import sys
import json
import ssl

try:
    from urllib.request import urlopen, Request
except ImportError:
    from urllib2 import urlopen, Request

try:
    from concurrent.futures import ThreadPoolExecutor
    HAVE_FUTURES = True
except ImportError:
    HAVE_FUTURES = False

DEFAULT_TIMEOUT = 3
PROBE_PATH = "/webman/3rdparty/Syno_Toolbox/api.cgi?action=pingtoolbox"


def _unverified_context():
    # Most home-lab NAS use DSM's self-signed cert on the admin port -
    # same trust model as fs_backup_upload's curl -k.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def probe_one(nas, timeout):
    ip = nas.get('ip')
    if not ip:
        return None
    port = nas.get('https_port', 5001)
    url = 'https://%s:%s%s' % (ip, port, PROBE_PATH)
    try:
        resp = urlopen(Request(url), timeout=timeout, context=_unverified_context())
        body = resp.read()
        data = json.loads(body.decode('utf-8') if isinstance(body, bytes) else body)
    except Exception:
        return None
    if not data.get('toolbox'):
        return None
    out = dict(nas)
    out['toolbox_port'] = port
    out['toolbox_hostname'] = data.get('hostname', nas.get('hostname'))
    return out


def probe_all(nas_list, timeout=DEFAULT_TIMEOUT):
    results = []
    if HAVE_FUTURES and nas_list:
        with ThreadPoolExecutor(max_workers=min(16, len(nas_list))) as ex:
            for r in ex.map(lambda n: probe_one(n, timeout), nas_list):
                if r:
                    results.append(r)
    else:
        # Python 2 without concurrent.futures (unlikely on modern DSM6,
        # but keep this working rather than crashing) - sequential.
        for n in nas_list:
            r = probe_one(n, timeout)
            if r:
                results.append(r)
    return results


def main():
    import argparse
    parser = argparse.ArgumentParser(
        description='Probe discovered NAS for a reachable Syno_Toolbox.')
    parser.add_argument('--timeout', type=int, default=DEFAULT_TIMEOUT,
                         help='Seconds to wait per probe (default: %d)' % DEFAULT_TIMEOUT)
    args = parser.parse_args()

    try:
        nas_list = json.loads(sys.stdin.read() or '[]')
    except Exception as e:
        sys.stderr.write('ERROR: could not parse input JSON: %s\n' % e)
        sys.exit(1)

    if not isinstance(nas_list, list):
        sys.stderr.write('ERROR: expected a JSON array on stdin\n')
        sys.exit(1)

    print(json.dumps(probe_all(nas_list, timeout=args.timeout)))


if __name__ == '__main__':
    main()

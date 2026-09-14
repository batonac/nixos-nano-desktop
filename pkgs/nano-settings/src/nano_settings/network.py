"""One question, asked once, right before it matters: can this machine reach
a binary cache?

The app has no other interest in the network. It exists for the Apply gate
in window.py: a change to an option whose other values are not on the
install media (datatypes.SchemaEntry.installMedia) is a download, and on a
machine with no route out that download is a rebuild that fails twenty
minutes in, after the password prompt. Better to say so before either.

cache.nixos.org rather than a generic reachability check, because it is the
thing the rebuild will actually talk to; a captive portal answering 200 for
everything is the false positive, and the rebuild's own failure remains the
backstop for that. HEAD, three seconds, no retries: this runs on the main
thread between a click and a dialog.
"""

from __future__ import annotations

from urllib.error import URLError
from urllib.request import Request, urlopen

CACHE_URL = "https://cache.nixos.org/nix-cache-info"


def is_online(timeout: float = 3.0) -> bool:
    request = Request(CACHE_URL, method="HEAD")
    try:
        with urlopen(request, timeout=timeout) as response:
            status = int(response.status)
    except (URLError, TimeoutError, OSError):
        return False
    return 200 <= status < 400

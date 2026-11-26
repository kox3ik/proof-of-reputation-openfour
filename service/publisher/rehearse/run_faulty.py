"""Rehearsal entry: the normal daemon with injected send faults. While $FAULT_FILE holds N > 0 the next N sends fail (nothing is
sent, an error is raised); while $FAULT_LOST holds N > 0 the next N sends reach the node but the answer is lost. Each use
decrements the file."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import chain  # noqa: E402
import run  # noqa: E402

_orig = chain.Chain.send_raw


def send_raw(self, raw):
    f = os.environ.get("FAULT_FILE")
    if f and os.path.exists(f):
        n = int(open(f).read().strip() or 0)
        if n > 0:
            open(f, "w").write(str(n - 1))
            raise chain.RpcError("injected send failure")
    lost = os.environ.get("FAULT_LOST")
    if lost and os.path.exists(lost):
        n = int(open(lost).read().strip() or 0)
        if n > 0:
            open(lost, "w").write(str(n - 1))
            _orig(self, raw)  # the node takes the tx, the answer is lost
            raise chain.RpcError("injected lost answer")
    return _orig(self, raw)


chain.Chain.send_raw = send_raw
run.main()

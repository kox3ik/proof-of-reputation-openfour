import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PUB = os.path.abspath(os.path.join(HERE, ".."))
if PUB not in sys.path:
    sys.path.insert(0, PUB)

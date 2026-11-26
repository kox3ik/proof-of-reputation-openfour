"""JSON-RPC client for the target network (polling only; no WebSocket)."""
from __future__ import annotations

import time

import requests


class RpcError(RuntimeError):
    pass


class RpcRejected(RpcError):
    """The node answered with a JSON-RPC error: the request definitely did not take effect (as opposed to a lost answer)."""


class Chain:
    def __init__(self, url: str, timeout: float = 15.0) -> None:
        self.url = url
        self.s = requests.Session()
        self.timeout = timeout
        self._id = 0

    def call(self, method: str, params: list):
        self._id += 1
        for attempt in range(3):
            try:
                r = self.s.post(self.url, json={"jsonrpc": "2.0", "id": self._id, "method": method, "params": params},
                                timeout=self.timeout)
                j = r.json()
                break
            except (requests.RequestException, ValueError) as e:
                if attempt == 2:
                    raise RpcError(f"{method}: {e}") from e
                time.sleep(0.2 * (attempt + 1))
        if "error" in j:
            raise RpcRejected(f"{method}: {j['error']}")
        return j["result"]

    def chain_id(self) -> int:
        return int(self.call("eth_chainId", []), 16)

    def head(self) -> int:
        return int(self.call("eth_blockNumber", []), 16)

    def block(self, n: int, full: bool = False) -> dict:
        b = self.call("eth_getBlockByNumber", [hex(n), full])
        if b is None:
            raise RpcError(f"block {n} not available")
        return b

    def logs(self, lo: int, hi: int, address: str, topics: list) -> list[dict]:
        return self.call("eth_getLogs", [{"fromBlock": hex(lo), "toBlock": hex(hi), "address": address, "topics": topics}])

    def logs_of_block(self, block_hash: str, address: str, topics: list) -> list[dict]:
        """Second, independent query: the same logs by block hash (cross-check of the range query)."""
        return self.call("eth_getLogs", [{"blockHash": block_hash, "address": address, "topics": topics}])

    def gas_limit(self) -> int:
        return int(self.call("eth_getBlockByNumber", ["latest", False])["gasLimit"], 16)

    def eth_call(self, to: str, data: str) -> str:
        return self.call("eth_call", [{"to": to, "data": data}, "latest"])

    def uint(self, to: str, data: str) -> int:
        return int(self.eth_call(to, data), 16)

    def nonce(self, addr: str, tag: str = "pending") -> int:
        return int(self.call("eth_getTransactionCount", [addr, tag]), 16)

    def gas_price(self) -> int:
        return int(self.call("eth_gasPrice", []), 16)

    def estimate_gas(self, frm: str, to: str, data: str) -> int:
        return int(self.call("eth_estimateGas", [{"from": frm, "to": to, "data": data}]), 16)

    def send_raw(self, raw: bytes) -> str:
        return self.call("eth_sendRawTransaction", ["0x" + raw.hex()])

    def receipt(self, h: str) -> dict | None:
        return self.call("eth_getTransactionReceipt", [h])

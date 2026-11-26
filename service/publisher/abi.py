"""ABI pieces the publisher needs: OpenFour Core events and the registry's `publish` / reads (no external ABI library)."""
from __future__ import annotations

from typing import NamedTuple

from txsign import keccak256

TRADE_SIG = ("TradeExecuted(address,address,uint256,bool,address,address,uint256,uint256,uint256,uint256,uint256,uint256,"
             "uint256,uint256,uint256,uint256,uint256,uint256)")
CREATED_SIG = ("TokenCreated(uint256,uint256,address,address,string,string,uint256,uint256,uint256,uint256,address,address,"
               "address,address,address,address,address,string,uint256,bytes)")
PUBLISH_SIG = "publish(uint64,address[],(uint16,uint16,uint16,uint16,uint16)[],uint64,uint64,bytes32,uint64[])"


def topic(sig: str) -> str:
    return "0x" + keccak256(sig.encode()).hex()


def selector(sig: str) -> str:
    return "0x" + keccak256(sig.encode())[:4].hex()


TRADE_TOPIC = topic(TRADE_SIG)
CREATED_TOPIC = topic(CREATED_SIG)
CURRENT_EPOCH = selector("currentEpoch()")
COVERED_UNTIL = selector("coveredUntil()")
UPDATER = selector("updater()")
DEPLOYED_AT = selector("deployedAt()")


class Trade(NamedTuple):
    token: str
    trader: str
    is_buy: bool
    quote_asset: str
    token_amount: int
    curve_quote: int
    last_price: int
    block: int
    tx_hash: str
    tx_index: int
    log_index: int


class Created(NamedTuple):
    token: str
    block: int
    max_supply: int  # raw, 18 decimals


def _w(data: str, i: int) -> int:
    return int(data[2 + 64 * i: 66 + 64 * i], 16)


def _addr(topic_hex: str) -> str:
    return "0x" + topic_hex[-40:].lower()


def parse_trade(log: dict) -> Trade:
    d = log["data"]
    return Trade(_addr(log["topics"][1]), _addr(log["topics"][2]), bool(_w(d, 0)), "0x" + d[2 + 64 + 24: 66 + 64].lower(),
                 _w(d, 4), _w(d, 5), _w(d, 7), int(log["blockNumber"], 16), log["transactionHash"],
                 int(log["transactionIndex"], 16), int(log["logIndex"], 16))


def parse_created(log: dict) -> Created:
    """data words: requestId(0), name offset(1), symbol offset(2), maxSupply(3), ..."""
    return Created(_addr(log["topics"][3]), int(log["blockNumber"], 16), _w(log["data"], 3))


def _u(x: int) -> str:
    return f"{x:064x}"


def encode_publish(epoch: int, wallets: list[str], comps: list[tuple[int, int, int, int, int]], covered_until: int,
                   source_block: int, source_hash: str, since: list[int]) -> str:
    """Calldata of publish(epoch, wallets, comps, coveredUntil, sourceBlock, sourceHash, since). `since[i]` = start of the rug
    activity of wallet i (used only for flagged wallets, 0 otherwise). Static tuple array: 5 words each."""
    n = len(wallets)
    off_w = 7 * 32
    off_c = off_w + 32 + 32 * n
    off_s = off_c + 32 + 160 * n
    head = (_u(epoch) + _u(off_w) + _u(off_c) + _u(covered_until) + _u(source_block) + source_hash[2:].rjust(64, "0") + _u(off_s))
    body_w = _u(n) + "".join(_u(int(a, 16)) for a in wallets)
    body_c = _u(len(comps)) + "".join("".join(_u(v) for v in c) for c in comps)
    body_s = _u(len(since)) + "".join(_u(v) for v in since)
    return selector(PUBLISH_SIG) + head + body_w + body_c + body_s

#!/usr/bin/env python3
"""Compute the Fabric block header hash from a decoded block JSON (configtxlator output).

Fabric: hash = SHA-256(ASN.1 DER of SEQUENCE{ INTEGER number, OCTET STRING previous_hash, OCTET STRING data_hash })
(protoutil.BlockHeaderHash). Usage: blockhash.py <block.json>  -> prints base64 hash
"""
import base64
import hashlib
import json
import sys


def der_len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def der_int(v: int) -> bytes:
    b = v.to_bytes(max(1, (v.bit_length() + 8) // 8), "big", signed=True)
    return b"\x02" + der_len(len(b)) + b


def der_octets(b: bytes) -> bytes:
    return b"\x04" + der_len(len(b)) + b


def main() -> None:
    with open(sys.argv[1], encoding="utf-8") as f:
        hdr = json.load(f)["header"]
    body = der_int(int(hdr.get("number", "0"))) + der_octets(base64.b64decode(hdr.get("previous_hash") or "")) \
        + der_octets(base64.b64decode(hdr.get("data_hash") or ""))
    seq = b"\x30" + der_len(len(body)) + body
    print(base64.b64encode(hashlib.sha256(seq).digest()).decode())


if __name__ == "__main__":
    main()

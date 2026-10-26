#!/usr/bin/env python3
"""Builds minimal GGUF fixtures so the header parser can be tested off-device.

Each fixture targets one failure mode we have actually seen in the field:
  good.gguf       – well-formed, must parse to valid+complete
  truncated.gguf  – data section cut in half, must report incomplete
  notgguf.gguf    – HDF5 header renamed to .gguf (common when users grab the
                    wrong file from a model repo)
  v2_array.gguf   – GGUF v2 with a 2000-entry tokenizer array, which is where a
                    mis-sized skip desynchronises the whole metadata stream
"""

import os
import struct

OUT = os.path.join(os.path.dirname(__file__), "fixtures")


def s(x):
    b = x.encode() if isinstance(x, str) else x
    return struct.pack("<Q", len(b)) + b


def kv_str(k, v):
    return s(k) + struct.pack("<I", 8) + s(v)


def kv_u32(k, v):
    return s(k) + struct.pack("<I", 4) + struct.pack("<I", v)


def kv_str_array(k, items):
    out = s(k) + struct.pack("<I", 9) + struct.pack("<I", 8) + struct.pack("<Q", len(items))
    for it in items:
        out += s(it)
    return out


def build_simple(full=True):
    out = b"GGUF" + struct.pack("<I", 3) + struct.pack("<Q", 1) + struct.pack("<Q", 4)
    out += kv_str("general.architecture", "llama")
    out += kv_u32("general.file_type", 15)  # Q4_K_M
    out += kv_u32("llama.context_length", 2048)
    out += kv_str("tokenizer.chat_template", "<|im_start|>{{role}}\n{{content}}<|im_end|>")
    out += s("token_embd.weight") + struct.pack("<I", 2)
    out += struct.pack("<Q", 32) + struct.pack("<Q", 32)
    out += struct.pack("<I", 0) + struct.pack("<Q", 0)  # F32, offset 0
    out += b"\0" * ((32 - len(out) % 32) % 32)
    data = 32 * 32 * 4
    out += (b"\x11" * data) if full else (b"\x11" * (data // 2))
    return out


def build_v2_array():
    toks = ["<unk>", "<s>", "</s>"] + [f"tok{i}" for i in range(2000)]
    out = b"GGUF" + struct.pack("<I", 2) + struct.pack("<Q", 2) + struct.pack("<Q", 5)
    out += kv_str("general.architecture", "qwen2")
    out += kv_str_array("tokenizer.ggml.tokens", toks)
    out += kv_u32("general.file_type", 14)  # Q4_K_S
    out += kv_u32("qwen2.context_length", 4096)
    out += kv_u32("qwen2.attention.head_count", 12)
    out += s("blk.0.attn_q.weight") + struct.pack("<I", 2)
    out += struct.pack("<Q", 64) + struct.pack("<Q", 64)
    out += struct.pack("<I", 1) + struct.pack("<Q", 0)  # F16
    out += s("blk.0.ffn.weight") + struct.pack("<I", 1) + struct.pack("<Q", 256)
    out += struct.pack("<I", 12) + struct.pack("<Q", 64 * 64 * 2)  # Q4_K
    out += b"\0" * ((32 - len(out) % 32) % 32)
    out += b"\x22" * (64 * 64 * 2 + 144)
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "good.gguf"), "wb").write(build_simple(True))
    open(os.path.join(OUT, "truncated.gguf"), "wb").write(build_simple(False))
    open(os.path.join(OUT, "notgguf.gguf"), "wb").write(b"\x89HDF\r\n\x1a\n" + b"\0" * 100)
    open(os.path.join(OUT, "v2_array.gguf"), "wb").write(build_v2_array())
    print(f"fixtures written to {OUT}")


if __name__ == "__main__":
    main()

import hashlib
import pathlib
import struct

ROOT = pathlib.Path(__file__).resolve().parents[2]


def multiply(a, b):
    return ((a or 65536) * (b or 65536) % 65537) & 65535


def encrypt_block(block, key):
    value = int.from_bytes(key, 'big')
    mask = (1 << 128) - 1
    keys = []
    while len(keys) < 52:
        keys.extend((value >> shift) & 65535 for shift in range(112, -1, -16))
        value = ((value << 25) | (value >> 103)) & mask
    x1, x2, x3, x4 = struct.unpack('>4H', block)
    for index in range(0, 48, 6):
        x1 = multiply(x1, keys[index])
        x2 = (x2 + keys[index + 1]) & 65535
        x3 = (x3 + keys[index + 2]) & 65535
        x4 = multiply(x4, keys[index + 3])
        t0 = multiply(x1 ^ x3, keys[index + 4])
        t1 = multiply(((x2 ^ x4) + t0) & 65535, keys[index + 5])
        t0 = (t0 + t1) & 65535
        x1, x2, x3, x4 = x1 ^ t1, x3 ^ t1, x2 ^ t0, x4 ^ t0
    return struct.pack('>4H', multiply(x1, keys[48]), (x3 + keys[49]) & 65535,
                       (x2 + keys[50]) & 65535, multiply(x4, keys[51]))


def cfb64(plaintext, key):
    feedback = bytes.fromhex('507e4c17993a0701')
    ciphertext = bytearray()
    for offset in range(0, len(plaintext), 8):
        block = plaintext[offset:offset + 8]
        stream = encrypt_block(feedback, key)
        encrypted = bytes(a ^ b for a, b in zip(block, stream))
        ciphertext.extend(encrypted)
        feedback = encrypted
    return ciphertext


vector_key = bytes.fromhex('00112233445566778899aabbccddeeff')
for plaintext, ciphertext in [
    ('000102030405060708090a0b0c0d0e0f', 'ed732271a7b39f475b4b2b6719f194bf'),
    ('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff', 'b8bc6ed5c899265d2bcfad1fc6d4287d')]:
    blocks = bytes.fromhex(plaintext)
    assert b''.join(encrypt_block(blocks[i:i + 8], vector_key) for i in range(0, len(blocks), 8)).hex() == ciphertext

key = bytes.fromhex((ROOT / 'Tests/Fixtures/broken-md5.txt').read_text().strip())
title = 'Legacy imported note'.encode('utf-16')
body = 'Preserved legacy IDEA content: café 日本語\n[[Project Alpha]]'.encode('utf-16')
header = hashlib.sha1('legacy import: café 日本語'.encode()).digest() + struct.pack('>I', 1)
database = header + struct.pack('>I', len(title)) + cfb64(title, key)
database += struct.pack('>II', len(body), len(body)) + cfb64(body, key)
(ROOT / 'Tests/Fixtures/legacy-idea.blor').write_bytes(database)

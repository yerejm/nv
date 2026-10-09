"""Derives databases and journals of other epochs from the captured epoch-4 fixtures.

Epoch-2 and epoch-3 archives keep the captured notes but use the key set that the archivers of
that epoch wrote (NotationPrefs.m and NoteObject.m at bfcbfa1^ for epoch 2 and f2632de^ for
epoch 3). Epoch-5 fixtures follow the authenticated format: an upgraded database that keeps its
PBKDF2-SHA1 master key, a database whose passphrase was set with PBKDF2-SHA256, and a journal of
authenticated records. Ciphertext comes from the system LibreSSL command and digests from Python,
so the application's crypto code is not used to create any of them.
"""
import hashlib
import hmac
import pathlib
import plistlib
import struct
import subprocess
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURES = ROOT / 'Tests/Fixtures'
PASSWORD = b'sanitized fixture password'
VERIFY_SALT = b'Salt for verifying master key in a single iteration\0'
DATABASE_ENCRYPTION = b'Notational Velocity database encryption'
DATABASE_AUTHENTICATION = b'Notational Velocity database authentication'
JOURNAL_ENCRYPTION = b'Notational Velocity journal encryption'
JOURNAL_AUTHENTICATION = b'Notational Velocity journal authentication'
JOURNAL_MAGIC = b'NVWAL\0\0\x05'
PRF_SHA1, PRF_SHA256 = 1, 3

PREFS_KEYS_ADDED_AFTER = {
    2: ['foregroundColor', 'seenDiskUUIDEntries'] + [f'chosenExtIndices.{i}' for i in range(4)],
    3: [f'chosenExtIndices.{i}' for i in range(4)],
}
NOTE_KEYS_ADDED_AFTER = {
    2: ['perDiskInfoGroups', 'logicalSize', 'fileModifiedDate'],
    3: ['perDiskInfoGroups'],
}
NOTE_KEYS_RETIRED = {
    2: {'fileModDateHigh': 0, 'fileModDateLow': 1262304000, 'fileModDateFrac': 0, 'nodeID': 4242},
    3: {'attrModDiskPairs': b'', 'nodeID': 4242},
}


def class_name(archive, item):
    if not isinstance(item, dict) or '$class' not in item:
        return None
    return archive['$objects'][item['$class'].data]['$classname']


def objects_of_class(archive, name):
    return [item for item in archive['$objects'] if class_name(archive, item) == name]


def resolve(archive, value):
    return archive['$objects'][value.data] if isinstance(value, plistlib.UID) else value


def data_bytes(archive, value):
    value = resolve(archive, value)
    return value['NS.data'] if isinstance(value, dict) else value


def openssl_aes(data, key, iv, decrypt):
    arguments = ['/usr/bin/openssl', 'enc', '-aes-256-cbc', '-K', key.hex(), '-iv', iv.hex()]
    return subprocess.run(arguments + (['-d'] if decrypt else []), input=data, capture_output=True, check=True).stdout


def session_cipher(prefs, archive):
    salt = data_bytes(archive, prefs['masterSalt'])
    session_salt = data_bytes(archive, prefs['dataSessionSalt'])
    master_key = hashlib.pbkdf2_hmac('sha1', PASSWORD, salt, prefs['hashIterationCount'], 32)
    return hashlib.pbkdf2_hmac('sha1', master_key, session_salt, 1, 32), session_salt[:16]


def derive_notes(data, epoch):
    original_length, = struct.unpack('>I', data[-4:])
    notes = plistlib.loads(zlib.decompress(data[:-4]))
    assert len(zlib.decompress(data[:-4])) == original_length
    for note in objects_of_class(notes, 'NoteObject'):
        for key in NOTE_KEYS_ADDED_AFTER[epoch]:
            del note[key]
        note.update(NOTE_KEYS_RETIRED[epoch])
    serialized = plistlib.dumps(notes, fmt=plistlib.FMT_BINARY, sort_keys=False)
    return zlib.compress(serialized) + struct.pack('>I', len(serialized))


def derive(source, epoch, destination):
    archive = plistlib.loads((FIXTURES / source).read_bytes())
    prefs, = objects_of_class(archive, 'NotationPrefs')
    prefs['epochIteration'] = epoch
    for key in PREFS_KEYS_ADDED_AFTER[epoch]:
        prefs.pop(key, None)
    frozen, = objects_of_class(archive, 'FrozenNotation')
    container = resolve(archive, frozen['notesData'])
    notes_data = container['NS.data']
    if prefs['doesEncryption']:
        key, iv = session_cipher(prefs, archive)
        notes_data = openssl_aes(derive_notes(openssl_aes(notes_data, key, iv, True), epoch), key, iv, False)
    else:
        notes_data = derive_notes(notes_data, epoch)
    container['NS.data'] = notes_data
    (FIXTURES / destination).write_bytes(plistlib.dumps(archive, fmt=plistlib.FMT_BINARY, sort_keys=False))


def subkey(key, purpose, salt=b''):
    return hashlib.pbkdf2_hmac('sha256', key, purpose + salt, 1, 32)


def derive_authenticated(destination, rekey):
    archive = plistlib.loads((FIXTURES / 'legacy-encrypted.database').read_bytes())
    prefs, = objects_of_class(archive, 'NotationPrefs')
    frozen, = objects_of_class(archive, 'FrozenNotation')
    container = resolve(archive, frozen['notesData'])
    key, iv = session_cipher(prefs, archive)
    plaintext = openssl_aes(container['NS.data'], key, iv, True)
    salt = data_bytes(archive, prefs['masterSalt'])
    session_salt = data_bytes(archive, prefs['dataSessionSalt'])
    if rekey:
        master_key = hashlib.pbkdf2_hmac('sha256', PASSWORD, salt, prefs['hashIterationCount'], 32)
        verifier = resolve(archive, prefs['verifierKey'])
        verifier['NS.data'] = hashlib.pbkdf2_hmac('sha256', master_key, VERIFY_SALT, 1, 32)
        prefs['keyDerivationPRF'] = PRF_SHA256
    else:
        master_key = hashlib.pbkdf2_hmac('sha1', PASSWORD, salt, prefs['hashIterationCount'], 32)
        prefs['keyDerivationPRF'] = PRF_SHA1
    iv = session_salt[:16]
    ciphertext = openssl_aes(plaintext, subkey(master_key, DATABASE_ENCRYPTION, session_salt), iv, False)
    tag = hmac.new(subkey(master_key, DATABASE_AUTHENTICATION, session_salt), iv + ciphertext, hashlib.sha256).digest()
    container['NS.data'] = ciphertext + tag
    prefs['epochIteration'] = 5
    (FIXTURES / destination).write_bytes(plistlib.dumps(archive, fmt=plistlib.FMT_BINARY, sort_keys=False))


def legacy_journal_records(data, key):
    inflater = zlib.decompressobj()
    while data:
        original_length, length, checksum = struct.unpack('>III', data[:12])
        salt, ciphertext, data = data[12:44], data[44:44 + length], data[44 + length:]
        assert zlib.crc32(ciphertext) == checksum
        record_key = hashlib.pbkdf2_hmac('sha1', key, salt, 1, 32)
        record = inflater.decompress(openssl_aes(ciphertext, record_key, salt[:16], True))
        assert len(record) == original_length
        yield record


def derive_authenticated_journal(destination):
    key = bytes(32)
    deflater = zlib.compressobj(5, zlib.DEFLATED, zlib.MAX_WBITS, 9)
    journal = bytearray(JOURNAL_MAGIC)
    for index, record in enumerate(legacy_journal_records((FIXTURES / 'legacy-deletion.journal').read_bytes(), key)):
        compressed = deflater.compress(record) + deflater.flush(zlib.Z_SYNC_FLUSH)
        iv = hashlib.sha256(b'fixture record iv %d' % index).digest()[:16]
        ciphertext = openssl_aes(compressed, subkey(key, JOURNAL_ENCRYPTION), iv, False)
        header = struct.pack('>II', len(record), len(ciphertext)) + iv
        tag = hmac.new(subkey(key, JOURNAL_AUTHENTICATION), header + ciphertext, hashlib.sha256).digest()
        journal += header + tag + ciphertext
    (FIXTURES / destination).write_bytes(bytes(journal))


if __name__ == '__main__':
    for epoch in (2, 3):
        for kind in ('plain', 'encrypted'):
            derive(f'legacy-{kind}.database', epoch, f'legacy-epoch{epoch}-{kind}.database')
    derive_authenticated('epoch5-upgraded-encrypted.database', rekey=False)
    derive_authenticated('epoch5-sha256-encrypted.database', rekey=True)
    derive_authenticated_journal('epoch5-deletion.journal')

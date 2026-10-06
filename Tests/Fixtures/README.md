# Compatibility fixtures

These committed fixtures contain only generated, sanitized notes. Tests consume them as fixed inputs and never regenerate them. No live user database was used.

- `deleted-keyed.archive` and `deleted-positional.archive`: captured with the unchanged DeletedNoteObject archive codecs; test class names, UUIDs, sequence numbers, and retired metadata.
- `legacy-plain.database`, `legacy-encrypted.database`, and `legacy-deletion.journal`: captured before remote removal using the unchanged NoteObject/FrozenNotation/NotationPrefs/WAL archive layouts. Encryption was supplied independently by the system LibreSSL command, replacing only the fixture generator's encryption method. Password: `sanitized fixture password`. These establish compatibility beyond a current-code round trip.
- `crypto-vectors.json`: fixed AES-256-CBC/PKCS7 ciphertext from system LibreSSL, including empty and Unicode payloads. CryptoTests also contains independent PBKDF2/SHA1 vectors and malformed-padding ciphertext.
- `broken-md5.txt`: captured historical digest of the UTF-8 password `legacy import: café 日本語`. The deliberately historical digest must remain compatible.
- `legacy-idea.blor`: independently constructed by `generate_legacy_blor.py`; the separate Python IDEA implementation is checked against two [Bouncy Castle IDEA test vectors](https://github.com/bcgit/bc-java/blob/main/core/src/test/java/org/bouncycastle/crypto/test/IDEATest.java) before creating CFB64 ciphertext. Password: `legacy import: café 日本語`.
- `hyperlink-policy.json`: the user's confirmed Foundation URL semantics plus compatibility handling, based on the saved 77-case comparison. Encoded path separators stay encoded; Spotify, Unicode email, wiki links, and trailing-delimiter behavior are covered.

Generator programs under `Tests/Tools` document provenance. Some historical generators use `/usr/bin/openssl` solely to create independent fixtures. Application builds, ordinary runs, and both test runners require no OpenSSL executable, headers, or library.

# Protocol data

Telegraph implements its protocol code in Swift. The repository includes public
Telegram protocol descriptions and public cryptographic constants as data:

- API schema, layer 225: https://core.telegram.org/schema/json
- MTProto schema: https://core.telegram.org/schema/mtproto-json
- DH prime and key-exchange description: https://core.telegram.org/mtproto/auth_key
- Server RSA public keys: https://github.com/tdlib/td/blob/master/td/telegram/net/PublicRsaKeySharedMain.cpp

The schema and key data were retrieved on 2026-10-17. The source JSON files and their
SHA-256 hashes in `EmbeddedSchemas.swift` identify the exact embedded versions.

The RSA modulus, exponent, and fingerprint values were extracted from TDLib's
published public-key data. Its source file identifies:

Copyright Aliaksei Levin (levlam@telegram.org), Arseny Smirnov
(arseny30@gmail.com) 2014–2026.

Distributed under the [Boost Software License, Version 1.0](https://www.boost.org/LICENSE_1_0.txt).
No TDLib library or source implementation is linked into Telegraph.

The test arithmetic fixtures were calculated independently using integer modular
arithmetic. The SRP fixture uses the server-side shared-secret equation, rather
than Telegraph's client-side equation. The single-block AES-256 known-answer test
uses the standard AES example with key bytes 00 through 1f and plaintext
00112233445566778899aabbccddeeff.

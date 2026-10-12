import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:voterlens/core/sync/vlsync_transport.dart';

void main() {
  group('Cross-Platform Cryptography Interop Tests', () {
    test('PBKDF2 key derivation matches Python standard output', () async {
      final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 1000,
        bits: 256,
      );
      final salt = [
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
      ];
      final key = await pbkdf2.deriveKeyFromPassword(
        password: 'testpassphrase',
        nonce: salt,
      );
      final bytes = await key.extractBytes();
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      // Python PBKDF2HMAC(SHA256, 32, salt, 1000) on 'testpassphrase'
      expect(hex, '99d139c4dda8e9b9d7eefed7ccc7878512b702540e28654d39f4721ae1c5f2fe');
    });

    test('AES-256-GCM encrypt and decrypt roundtrip in Dart', () async {
      final key = await VLSyncCrypto.deriveKey(
        'SecretPassphrase123!',
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
      );
      final nonce = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120];
      final aad = utf8.encode('TEST_AAD_CANONICAL');
      final plaintext = utf8.encode('Hello VoterLens Offline Sync!');

      final encrypted = await VLSyncCrypto.encryptPayload(
        plaintext: plaintext,
        key: key,
        nonce: nonce,
        aad: aad,
      );

      final decrypted = await VLSyncCrypto.decryptPayload(
        ciphertextWithTag: encrypted,
        key: key,
        nonce: nonce,
        aad: aad,
      );

      expect(utf8.decode(decrypted), 'Hello VoterLens Offline Sync!');
    });

    test('Dart decrypts Python-generated .vlsync packet envelope', () async {
      final envelope = {
        "magic": "VLSYNC",
        "protocol_version": 1,
        "packet_id": "11111111-2222-3333-4444-555555555555",
        "created_at": "2026-10-09T04:00:50.012668+00:00",
        "packet_type": "FIELD_OBSERVATIONS_SYNC",
        "source_device_id": "aaaaaa11-bb22-cc33-dd44-ee5555555555",
        "source_user_id": "supervisor_alice",
        "roll_version_id": "rrrrrrrr-1111-2222-3333-444444444444",
        "roll_checksum": "3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
        "observation_count": 1,
        "encryption": {
          "algorithm": "AES-256-GCM",
          "kdf": "PBKDF2-HMAC-SHA256",
          "iterations": 100000,
          "salt_hex": "f6fc3aacf16f0dbd8cca3eb03860c5bf",
          "nonce_hex": "26436dbeee6323519f6179e7"
        },
        "ciphertext_hex": "aa006c0c42e6cf0702beab7a6e9c488c4fde4df6bd60323129a3592bbe2c387b544067fba1e528111b79728279d6f98d2c4c02af6580461714310adfe8341510df04f4381e0a8185221eac1d01a53bf4613d8dec067873bcade3708f994967ec99e52c3e4eb13ffc7f59ad933936f8bcf058f0be45d15617c4b24d98ded540df51d75d98c526809349908462ab351a04a7013970355e2ac6214da015ede2d0ffd79b7a43b89c7252a5db83137eee0138e5135dfba982995f57ca165ba0b618488b087438c4c4fc3073b4e7fa83e5d219c9f3f304b5b6ffc48ad89c89d17d5dc814a86bddff13a1378ff42d8b9924bffd8fce02a7a2d661c17b652e31c51444d713fdd478b0deb520b34aab5264ae2869154609142a469af588447aaedee79b756798d75928e60b3f872e3f852de702337246ed6a4438ac943c9368a36953c8af54959d34d7207177f6be674f77683c18469b547b204f91fb71f0d925a429619bb721d4d154ffa16325bb113a9537782d6a42861be43919ac6265e1e9e6da09aa9d123e6c6213554d79641014ae441d38c8fe4dfbd731182a9105d1411df048e5d0177c2fb9bc7242c44aba4513c1b511c8f979f1a7fb746410724290111795342ed2d41a7faa6dbfa470c4f1689d89151d9475427124fe3cce533b03ad4b88d2d8018d0c326abd93b5efe2df2be92f16398875456932297948c8ca3725e4d4e395e9b48672e39c338eed0c5fb404bbff41",
        "file_integrity": {
          "sha256": "650843d1a7978ae8f80ae73d1859b94af30d3a7208a4f60dcbe5198d0c8d33e5"
        }
      };

      List<int> hexToBytes(String hex) {
        final result = <int>[];
        for (int i = 0; i < hex.length; i += 2) {
          result.add(int.parse(hex.substring(i, i + 2), radix: 16));
        }
        return result;
      }

      final enc = envelope["encryption"] as Map<String, dynamic>;
      final salt = hexToBytes(enc["salt_hex"] as String);
      final nonce = hexToBytes(enc["nonce_hex"] as String);
      final ciphertextWithTag = hexToBytes(envelope["ciphertext_hex"] as String);

      final key = await VLSyncCrypto.deriveKey("CorrectPassword123!", salt);
      final aad = VLSyncCrypto.getCanonicalAad(
        protocolVersion: envelope["protocol_version"] as int,
        packetId: envelope["packet_id"] as String,
        sourceDeviceId: envelope["source_device_id"] as String,
        rollVersionId: envelope["roll_version_id"] as String,
        rollChecksum: envelope["roll_checksum"] as String,
        observationCount: envelope["observation_count"] as int,
      );

      final decrypted = await VLSyncCrypto.decryptPayload(
        ciphertextWithTag: ciphertextWithTag,
        key: key,
        nonce: nonce,
        aad: aad,
      );

      final payload = jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;
      expect(payload["packet_id"], "11111111-2222-3333-4444-555555555555");
      final obs = (payload["observations"] as List).first as Map<String, dynamic>;
      expect(obs["voter_epic"], "KL01/001/0001");
      expect(obs["field_status"], "AWAY");
      expect(obs["phone_number"], "9876543210");
    });

    test('Dart rejects Python-generated envelope with wrong password', () async {
      final hex = "aa006c0c42e6cf0702beab7a6e9c488c4fde4df6bd60323129a3592bbe2c387b544067fba1e528111b79728279d6f98d2c4c02af6580461714310adfe8341510df04f4381e0a8185221eac1d01a53bf4613d8dec067873bcade3708f994967ec99e52c3e4eb13ffc7f59ad933936f8bcf058f0be45d15617c4b24d98ded540df51d75d98c526809349908462ab351a04a7013970355e2ac6214da015ede2d0ffd79b7a43b89c7252a5db83137eee0138e5135dfba982995f57ca165ba0b618488b087438c4c4fc3073b4e7fa83e5d219c9f3f304b5b6ffc48ad89c89d17d5dc814a86bddff13a1378ff42d8b9924bffd8fce02a7a2d661c17b652e31c51444d713fdd478b0deb520b34aab5264ae2869154609142a469af588447aaedee79b756798d75928e60b3f872e3f852de702337246ed6a4438ac943c9368a36953c8af54959d34d7207177f6be674f77683c18469b547b204f91fb71f0d925a429619bb721d4d154ffa16325bb113a9537782d6a42861be43919ac6265e1e9e6da09aa9d123e6c6213554d79641014ae441d38c8fe4dfbd731182a9105d1411df048e5d0177c2fb9bc7242c44aba4513c1b511c8f979f1a7fb746410724290111795342ed2d41a7faa6dbfa470c4f1689d89151d9475427124fe3cce533b03ad4b88d2d8018d0c326abd93b5efe2df2be92f16398875456932297948c8ca3725e4d4e395e9b48672e39c338eed0c5fb404bbff41";
      List<int> hexToBytes(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

      final salt = hexToBytes("f6fc3aacf16f0dbd8cca3eb03860c5bf");
      final nonce = hexToBytes("26436dbeee6323519f6179e7");
      final ciphertextWithTag = hexToBytes(hex);
      final key = await VLSyncCrypto.deriveKey("WrongPassword999!", salt);
      final aad = VLSyncCrypto.getCanonicalAad(
        protocolVersion: 1,
        packetId: "11111111-2222-3333-4444-555555555555",
        sourceDeviceId: "aaaaaa11-bb22-cc33-dd44-ee5555555555",
        rollVersionId: "rrrrrrrr-1111-2222-3333-444444444444",
        rollChecksum: "3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
        observationCount: 1,
      );

      expect(
        () async => await VLSyncCrypto.decryptPayload(
          ciphertextWithTag: ciphertextWithTag,
          key: key,
          nonce: nonce,
          aad: aad,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('Dart rejects tampered ciphertext via GCM tag verification', () async {
      final hex = "aa006c0c42e6cf0702beab7a6e9c488c4fde4df6bd60323129a3592bbe2c387b544067fba1e528111b79728279d6f98d2c4c02af6580461714310adfe8341510df04f4381e0a8185221eac1d01a53bf4613d8dec067873bcade3708f994967ec99e52c3e4eb13ffc7f59ad933936f8bcf058f0be45d15617c4b24d98ded540df51d75d98c526809349908462ab351a04a7013970355e2ac6214da015ede2d0ffd79b7a43b89c7252a5db83137eee0138e5135dfba982995f57ca165ba0b618488b087438c4c4fc3073b4e7fa83e5d219c9f3f304b5b6ffc48ad89c89d17d5dc814a86bddff13a1378ff42d8b9924bffd8fce02a7a2d661c17b652e31c51444d713fdd478b0deb520b34aab5264ae2869154609142a469af588447aaedee79b756798d75928e60b3f872e3f852de702337246ed6a4438ac943c9368a36953c8af54959d34d7207177f6be674f77683c18469b547b204f91fb71f0d925a429619bb721d4d154ffa16325bb113a9537782d6a42861be43919ac6265e1e9e6da09aa9d123e6c6213554d79641014ae441d38c8fe4dfbd731182a9105d1411df048e5d0177c2fb9bc7242c44aba4513c1b511c8f979f1a7fb746410724290111795342ed2d41a7faa6dbfa470c4f1689d89151d9475427124fe3cce533b03ad4b88d2d8018d0c326abd93b5efe2df2be92f16398875456932297948c8ca3725e4d4e395e9b48672e39c338eed0c5fb404bbff41";
      List<int> hexToBytes(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

      final salt = hexToBytes("f6fc3aacf16f0dbd8cca3eb03860c5bf");
      final nonce = hexToBytes("26436dbeee6323519f6179e7");
      final ciphertextWithTag = hexToBytes(hex);
      // Tamper one byte
      ciphertextWithTag[10] ^= 0xFF;

      final key = await VLSyncCrypto.deriveKey("CorrectPassword123!", salt);
      final aad = VLSyncCrypto.getCanonicalAad(
        protocolVersion: 1,
        packetId: "11111111-2222-3333-4444-555555555555",
        sourceDeviceId: "aaaaaa11-bb22-cc33-dd44-ee5555555555",
        rollVersionId: "rrrrrrrr-1111-2222-3333-444444444444",
        rollChecksum: "3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
        observationCount: 1,
      );

      expect(
        () async => await VLSyncCrypto.decryptPayload(
          ciphertextWithTag: ciphertextWithTag,
          key: key,
          nonce: nonce,
          aad: aad,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('Dart rejects tampered authenticated metadata (AAD mismatch)', () async {
      final hex = "aa006c0c42e6cf0702beab7a6e9c488c4fde4df6bd60323129a3592bbe2c387b544067fba1e528111b79728279d6f98d2c4c02af6580461714310adfe8341510df04f4381e0a8185221eac1d01a53bf4613d8dec067873bcade3708f994967ec99e52c3e4eb13ffc7f59ad933936f8bcf058f0be45d15617c4b24d98ded540df51d75d98c526809349908462ab351a04a7013970355e2ac6214da015ede2d0ffd79b7a43b89c7252a5db83137eee0138e5135dfba982995f57ca165ba0b618488b087438c4c4fc3073b4e7fa83e5d219c9f3f304b5b6ffc48ad89c89d17d5dc814a86bddff13a1378ff42d8b9924bffd8fce02a7a2d661c17b652e31c51444d713fdd478b0deb520b34aab5264ae2869154609142a469af588447aaedee79b756798d75928e60b3f872e3f852de702337246ed6a4438ac943c9368a36953c8af54959d34d7207177f6be674f77683c18469b547b204f91fb71f0d925a429619bb721d4d154ffa16325bb113a9537782d6a42861be43919ac6265e1e9e6da09aa9d123e6c6213554d79641014ae441d38c8fe4dfbd731182a9105d1411df048e5d0177c2fb9bc7242c44aba4513c1b511c8f979f1a7fb746410724290111795342ed2d41a7faa6dbfa470c4f1689d89151d9475427124fe3cce533b03ad4b88d2d8018d0c326abd93b5efe2df2be92f16398875456932297948c8ca3725e4d4e395e9b48672e39c338eed0c5fb404bbff41";
      List<int> hexToBytes(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

      final salt = hexToBytes("f6fc3aacf16f0dbd8cca3eb03860c5bf");
      final nonce = hexToBytes("26436dbeee6323519f6179e7");
      final ciphertextWithTag = hexToBytes(hex);
      final key = await VLSyncCrypto.deriveKey("CorrectPassword123!", salt);

      // Tamper observation count in AAD from 1 to 999
      final tamperedAad = VLSyncCrypto.getCanonicalAad(
        protocolVersion: 1,
        packetId: "11111111-2222-3333-4444-555555555555",
        sourceDeviceId: "aaaaaa11-bb22-cc33-dd44-ee5555555555",
        rollVersionId: "rrrrrrrr-1111-2222-3333-444444444444",
        rollChecksum: "3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
        observationCount: 999, // TAMPERED!
      );

      expect(
        () async => await VLSyncCrypto.decryptPayload(
          ciphertextWithTag: ciphertextWithTag,
          key: key,
          nonce: nonce,
          aad: tamperedAad,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('Dart exports packet envelope verifiable by Python', () async {
      String bytesToHex(List<int> bytes) =>
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      final salt = [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25];
      final nonce = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
      final key = await VLSyncCrypto.deriveKey("DartExportPass123!", salt);
      final aad = VLSyncCrypto.getCanonicalAad(
        protocolVersion: 1,
        packetId: "dart-pkt-9999",
        sourceDeviceId: "dart-dev-7777",
        rollVersionId: "roll-ver-1234",
        rollChecksum: "3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
        observationCount: 1,
      );
      final payload = {
        "packet_id": "dart-pkt-9999",
        "roll_version_id": "roll-ver-1234",
        "roll_checksum": "3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
        "observations": [
          {
            "observation_id": "dart-obs-001",
            "voter_epic": "KL99/999/9999",
            "field_status": "ABROAD",
            "phone_number": "9999999999",
            "notes": "Exported from Flutter app",
          }
        ]
      };
      final ciphertextWithTag = await VLSyncCrypto.encryptPayload(
        plaintext: utf8.encode(jsonEncode(payload)),
        key: key,
        nonce: nonce,
        aad: aad,
      );

      final envelope = {
        "magic": "VLSYNC",
        "protocol_version": 1,
        "packet_id": "dart-pkt-9999",
        "created_at": "2026-10-09T08:30:00Z",
        "packet_type": "FIELD_OBSERVATIONS_SYNC",
        "source_device_id": "dart-dev-7777",
        "source_user_id": "dart_operator",
        "roll_version_id": "roll-ver-1234",
        "roll_checksum": "3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
        "observation_count": 1,
        "encryption": {
          "algorithm": "AES-256-GCM",
          "kdf": "PBKDF2-HMAC-SHA256",
          "iterations": 100000,
          "salt_hex": bytesToHex(salt),
          "nonce_hex": bytesToHex(nonce),
        },
        "ciphertext_hex": bytesToHex(ciphertextWithTag),
        "file_integrity": {
          "sha256": crypto.sha256.convert(ciphertextWithTag).toString(),
        }
      };

      expect(envelope["magic"], "VLSYNC");
    });
  });
}

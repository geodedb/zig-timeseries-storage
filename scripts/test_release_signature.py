#!/usr/bin/env python3
"""Check release verification with real primary/subkey signatures and failures."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ReleaseSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="release-signature-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.env = dict(os.environ, GNUPGHOME=str(cls.root))
        cls.verifier = Path(__file__).with_name("verify-release-signature.sh")
        cls.gpg("--quick-generate-key", "Release test <test@example.invalid>",
                "ed25519", "cert,sign", "1d")
        keys = cls.gpg("--with-colons", "--list-keys").stdout
        cls.primary = next(line.split(":")[9] for line in keys.splitlines()
                           if line.startswith("fpr:"))
        cls.gpg("--quick-add-key", cls.primary, "ed25519", "sign", "1d")
        keys = cls.gpg("--with-colons", "--list-keys").stdout
        cls.subkey = [line.split(":")[9] for line in keys.splitlines()
                      if line.startswith("fpr:")][1]
        cls.payload = cls.root / "release.tar.gz"
        cls.payload.write_bytes(b"authenticated release payload\n")
        cls.signature = cls.root / "subkey.sig"
        cls.gpg("--local-user", cls.subkey + "!", "--output", str(cls.signature),
                "--detach-sign", str(cls.payload))
        cls.direct_signature = cls.root / "primary.sig"
        cls.gpg("--local-user", cls.primary + "!", "--output",
                str(cls.direct_signature), "--detach-sign", str(cls.payload))

    @classmethod
    def gpg(cls, *args):
        return subprocess.run(
            ["gpg", "--batch", "--yes", "--pinentry-mode", "loopback",
             "--passphrase", "", *args], env=cls.env, text=True,
            capture_output=True, check=True,
        )

    def verify(self, signature=None, payload=None, fingerprint=None):
        return subprocess.run(
            ["bash", str(self.verifier), str(signature or self.signature),
             str(payload or self.payload), fingerprint or self.primary],
            env=self.env, capture_output=True, text=True,
        ).returncode

    def test_certified_subkey_matches_primary(self):
        self.assertEqual(self.verify(), 0)

    def test_direct_primary_signature(self):
        self.assertEqual(self.verify(signature=self.direct_signature), 0)

    def test_subkey_is_not_a_primary_trust_anchor(self):
        self.assertNotEqual(self.verify(fingerprint=self.subkey), 0)

    def test_untrusted_primary_rejected(self):
        self.assertNotEqual(self.verify(fingerprint="A" * 40), 0)

    def test_tampered_payload_rejected(self):
        tampered = self.root / "tampered.tar.gz"
        tampered.write_bytes(b"modified payload\n")
        self.assertNotEqual(self.verify(payload=tampered), 0)

    def test_multiple_signatures_rejected(self):
        signatures = self.root / "multiple.sig"
        signatures.write_bytes(self.signature.read_bytes() * 2)
        self.assertNotEqual(self.verify(signature=signatures), 0)

    def test_invalid_fingerprint_rejected(self):
        self.assertEqual(self.verify(fingerprint=self.primary[-16:]), 2)


if __name__ == "__main__":
    unittest.main()

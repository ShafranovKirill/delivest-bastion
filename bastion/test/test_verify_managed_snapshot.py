import importlib.util
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "priv/verify-managed-snapshot.py"
spec = importlib.util.spec_from_file_location("verify_managed", SCRIPT)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class ManagedArchiveTest(unittest.TestCase):
    def make_archive(self, directory, corrupt=False, extra=None):
        payloads = {name: b"data" for name in verifier.FILES}
        payloads["project/release-manifest.json"] = b"release"
        files = {name: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
                 for name, data in payloads.items()}
        if corrupt:
            files["project/.env"]["sha256"] = "0" * 64
        manifest = {
            "schema_version": 1,
            "instance_id": "11111111-1111-1111-1111-111111111111",
            "project_name": "pilot",
            "placement_revision": 1,
            "release_version": "1.24.0",
            "release_manifest_sha256": files["project/release-manifest.json"]["sha256"],
            "captured_at": "2026-11-28T00:00:00Z",
            "files": files,
        }
        payloads["manifest.json"] = json.dumps(manifest).encode()
        if extra:
            payloads[extra] = b"unexpected"
        archive = directory / "snapshot.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            for name, data in payloads.items():
                item = tarfile.TarInfo(name)
                item.size = len(data)
                output.addfile(item, io.BytesIO(data))
        return archive

    def test_complete_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = self.make_archive(Path(temp))
            result = verifier.verify(archive, "11111111-1111-1111-1111-111111111111")
            self.assertEqual(result["release_version"], "1.24.0")

    def test_rejects_wrong_digest(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = self.make_archive(Path(temp), corrupt=True)
            with self.assertRaisesRegex(ValueError, "checksum"):
                verifier.verify(archive, "11111111-1111-1111-1111-111111111111")

    def test_rejects_unknown_or_unsafe_path(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = self.make_archive(Path(temp), extra="../secret")
            with self.assertRaisesRegex(ValueError, "unsafe"):
                verifier.verify(archive, "11111111-1111-1111-1111-111111111111")


if __name__ == "__main__":
    unittest.main()

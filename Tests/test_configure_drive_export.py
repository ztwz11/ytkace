import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "Tools" / "configure_drive_export.py"
CLIENT = "example-id.apps.googleusercontent.com"
BUNDLE = "com.example.ytkace.drive"


class ConfigureDriveExportTests(unittest.TestCase):
    def run_configure(self, path, client="", bundle=""):
        env = dict(os.environ, YTKACE_DRIVE_IOS_CLIENT_ID=client, YTKACE_DRIVE_IOS_BUNDLE_ID=bundle)
        return subprocess.run([sys.executable, str(SCRIPT), str(path)], env=env, capture_output=True)

    def test_optional_config_preserves_source_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "Info.plist"
            data = plistlib.dumps({"CFBundleIdentifier": "com.google.ios.youtube"})
            path.write_bytes(data)
            self.assertEqual(self.run_configure(path).returncode, 0)
            self.assertEqual(path.read_bytes(), data)

    def test_registration_is_idempotent_and_keeps_existing_schemes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "Info.plist"
            original = {"CFBundleIdentifier": "com.google.ios.youtube",
                        "CFBundleURLTypes": [{"CFBundleURLSchemes": ["youtube"]}]}
            path.write_bytes(plistlib.dumps(original))
            for _ in range(2):
                self.assertEqual(self.run_configure(path, CLIENT, BUNDLE).returncode, 0)
            result = plistlib.loads(path.read_bytes())
            self.assertEqual(result["CFBundleIdentifier"], original["CFBundleIdentifier"])
            self.assertEqual(result["YTKACEDriveClientID"], CLIENT)
            self.assertEqual(result["YTKACEDriveBundleID"], BUNDLE)
            self.assertEqual(result["CFBundleURLTypes"][0], original["CFBundleURLTypes"][0])
            self.assertEqual(result["CFBundleURLTypes"][1]["CFBundleURLSchemes"],
                             ["com.googleusercontent.apps.example-id"])
            self.assertEqual(len(result["CFBundleURLTypes"]), 2)

    def test_requires_client_id_and_bundle_id_together(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "Info.plist"
            data = plistlib.dumps({})
            for client, bundle in [(CLIENT, ""), ("", BUNDLE), ("invalid", BUNDLE), (CLIENT, "invalid")]:
                with self.subTest(client=client, bundle=bundle):
                    path.write_bytes(data)
                    self.assertNotEqual(self.run_configure(path, client, bundle).returncode, 0)
                    self.assertEqual(path.read_bytes(), data)


if __name__ == "__main__":
    unittest.main()

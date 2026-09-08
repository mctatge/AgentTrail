import importlib.util
import pathlib
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("publication", pathlib.Path(__file__).with_name("check-publication.py"))
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class PublicationTests(unittest.TestCase):
    def test_source_and_public_links_are_allowed(self):
        for name in ["README.md", "Sources/TrailCore/Demo.swift", ".github/workflows/ci.yml"]:
            self.assertEqual(publication.check_blob(name, "100644", b"https://github.com/mctatge/AgentTrail"), [])

    def test_recordings_builds_and_private_config_are_rejected(self):
        for name in ["events.jsonl", "exports/timeline.md", "library.sqlite", "frames/screen.png", "dist/AgentTrail.app", ".env", ".mcp.json", "docs/.private/note.md"]:
            self.assertTrue(publication.check_blob(name, "100644", b"private"))

    def test_symlinks_and_submodules_are_rejected(self):
        for mode in ["120000", "160000"]:
            self.assertTrue(publication.check_blob("README.md", mode, b"elsewhere"))

    def test_credentials_paths_and_recordings_are_rejected(self):
        samples = [
            "gh" + "p_" + "a" * 36,
            "sk-" + "proj-" + "a" * 40,
            "AK" + "IA" + "A" * 16,
            "-----BEGIN " + "PRIVATE KEY-----",
            "/Users" + "/private-user/document",
            "test-person@" + "gmail.com",
            '{"sessionID": "private", ' + '"timestamp": 123}',
        ]
        for sample in samples:
            self.assertTrue(publication.check_blob("README.md", "100644", sample.encode()))

    def test_binary_and_large_files_are_rejected(self):
        for data in [b"\x00binary", b"SQLite format 3", b"\xff\xfe", b"a" * (512 * 1024 + 1)]:
            self.assertTrue(publication.check_blob("README.md", "100644", data))

    def test_private_terms_are_case_insensitive_and_not_echoed(self):
        self.assertEqual(publication.check_blob("README.md", "100644", b"PRIVATE EXAMPLE", ["private example"]), ["private review term"])

    def test_checks_index_instead_of_cleaned_working_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(["git", "init", "--quiet", directory], check=True)
            readme = root / "README.md"
            readme.write_text("gh" + "p_" + "a" * 36)
            subprocess.run(["git", "add", "README.md"], cwd=root, check=True)
            readme.write_text("clean working copy")
            count, failures = publication.check_index(root)
            self.assertEqual(count, 1)
            self.assertEqual(failures[0][1], ["GitHub credential"])
            subprocess.run(["git", "add", "README.md"], cwd=root, check=True)
            self.assertEqual(publication.check_index(root), (1, []))

    def test_empty_index_is_not_claimed_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(["git", "init", "--quiet", directory], check=True)
            self.assertTrue(publication.check_index(pathlib.Path(directory))[1])


if __name__ == "__main__":
    unittest.main()

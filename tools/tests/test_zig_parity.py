import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import subprocess

spec = importlib.util.spec_from_file_location('zig_parity', Path(__file__).parents[1] / 'zig-parity.py')
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)


class InventoryTests(unittest.TestCase):
    def test_headings_keep_nested_text_and_order(self):
        parser = parity.Headings()
        parser.feed('<h1 id="a"> Language <code>Types</code> </h1><p>no</p><h2>Next &amp; Last</h2>')
        self.assertEqual(parser.rows, [{'level': 1, 'id': 'a', 'text': 'Language Types'}, {'level': 2, 'id': None, 'text': 'Next & Last'}])

    def test_env_field_uses_named_zon_string(self):
        self.assertEqual(parity.env_field('.{ .std_dir = "/a/std", .version = "v" }', 'std_dir'), '/a/std')
        with self.assertRaises(ValueError):
            parity.env_field('.{ .std_dir = null }', 'std_dir')

    def test_commands_excludes_options_and_supports_punctuation(self):
        self.assertEqual(parity.commands('Commands:\n\n  c++              C compiler\n  test-obj         Object tests\n\nGeneral Options:\n  -h   Help'), [{'name': 'c++', 'description': 'C compiler'}, {'name': 'test-obj', 'description': 'Object tests'}])

    def test_command_failure_keeps_diagnostic_and_aborts(self):
        failure = subprocess.CompletedProcess(['zig', 'version'], 1, b'', b'broken installation')
        with patch.object(parity.subprocess, 'run', return_value=failure):
            with self.assertRaisesRegex(RuntimeError, 'exited 1: broken installation'):
                parity.run('zig', 'version')

    def test_hash_is_content_sensitive(self):
        self.assertEqual(parity.digest(b'abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
        self.assertNotEqual(parity.digest(b'abc'), parity.digest(b'abd'))


if __name__ == '__main__':
    unittest.main()

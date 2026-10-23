import unittest

from rinkmasterd import __main__ as entry


class EntryPointTests(unittest.TestCase):
    def test_defaults(self):
        a = entry.parse_args([])
        self.assertEqual((a.host, a.port), ("0.0.0.0", 8472))
        self.assertEqual(a.roms, "/home/pi/RetroPie/roms")
        self.assertEqual(a.configs, "/opt/retropie/configs")

    def test_overrides_and_build_server_binds_a_port(self):
        a = entry.parse_args(["--host", "127.0.0.1", "--port", "0", "--roms", "/tmp/x", "--configs", "/tmp/y"])
        httpd = entry.build_server(a)
        try:
            self.assertEqual(httpd.server_address[0], "127.0.0.1")
            self.assertGreater(httpd.server_address[1], 0)
        finally:
            httpd.server_close()


if __name__ == "__main__":
    unittest.main()

"""可在 Linux 或安装了 Git Bash 的 Windows 上运行，不修改主机网络。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('NFTABLES_TEST_BASH') or shutil.which('bash')
if not BASH and os.name == 'nt':
    BASH = str(Path(os.environ['LOCALAPPDATA']) / 'Programs/Git/bin/bash.exe')


class NftablesTests(unittest.TestCase):
    def setUp(self):
        (PROJECT / '.test-work').mkdir(exist_ok=True)
        self.work = tempfile.TemporaryDirectory(prefix='nftables-', dir=PROJECT / '.test-work')
        self.root = Path(self.work.name)
        self.conf = self.root / 'nftables.json'
        self.conf.write_text('{"version":1,"rules":[]}', encoding='utf-8')

    def tearDown(self):
        self.work.cleanup()

    def shell(self, code, *args, ok=True):
        env = dict(os.environ, PYTHONUTF8='1', PYTHONIOENCODING='utf-8', NFT_TEST_PYTHON=sys.executable.replace('\\', '/'),
                   NFT_TEST_SCRIPT=str(PROJECT / 'nftables.sh').replace('\\', '/'),
                   NFT_TEST_ROOT=str(self.root).replace('\\', '/'))
        prefix = '''source "$NFT_TEST_SCRIPT"
python3() { "$NFT_TEST_PYTHON" "$@"; }
if command -v cygpath >/dev/null; then DIR=$(cygpath -u "$NFT_TEST_ROOT"); else DIR=$NFT_TEST_ROOT; fi
CONF=$DIR/nftables.json; RULES=$DIR/nftables.nft; RT=$DIR/nftables; UNIT=$DIR/nftables.service; LOCK=$DIR/nftables.lock
'''
        result = subprocess.run([BASH, '-c', prefix + code, 'test', *map(str, args)],
                                env=env, text=True, encoding='utf-8', capture_output=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def save(self, listen='18080', address='192.0.2.10', target='8080', protocol='tcp+udp', name='测试'):
        result = self.shell('config_tool save "$CONF" -1 "$1" "$2" "$3" "$4" "$5"', listen, address, target, protocol, name)
        self.conf.write_text(result.stdout, encoding='utf-8')

    def test_render_tcp_udp_scopes_nat_to_local_addresses(self):
        self.save()
        result = self.shell('config_tool render "$CONF"')
        self.assertIn('table ip nftables', result.stdout)
        self.assertIn('fib daddr type local tcp dport 18080', result.stdout)
        self.assertIn('fib daddr type local udp dport 18080', result.stdout)
        self.assertIn('dnat to 192.0.2.10:8080', result.stdout)
        self.assertEqual(result.stdout.count('counter masquerade'), 2)
        self.assertNotIn('flush ruleset', result.stdout)

    def test_bad_addresses_ports_and_names_rejected(self):
        for values in [('0', '192.0.2.10', '80'), ('65536', '192.0.2.10', '80'),
                       ('80', '999.1.1.1', '80'), ('80', '127.0.0.1', '80'),
                       ('80', '::1', '80'), ('80', 'x; flush ruleset', '80')]:
            with self.subTest(values=values):
                self.shell('config_tool input "$@"', *values, ok=False)
        self.save(name='valid')
        data = json.loads(self.conf.read_text(encoding='utf-8'))
        data['rules'][0]['name'] = 'bad\nname'
        self.conf.write_text(json.dumps(data), encoding='utf-8')
        self.shell('config_tool validate "$CONF"', ok=False)

    def test_duplicate_protocol_rejected_but_tcp_udp_can_share_port(self):
        self.save(protocol='tcp')
        self.shell('config_tool save "$CONF" -1 18080 192.0.2.20 80 tcp duplicate', ok=False)
        self.shell('config_tool save "$CONF" -1 18080 192.0.2.20 80 udp separate')
        self.shell('config_tool save "$CONF" -1 18080 192.0.2.20 80 tcp+udp duplicate', ok=False)

    def test_cancel_and_eof(self):
        self.shell("read_input answer test <<< Q; [[ $MENU_CANCELLED == 1 ]]")
        self.shell("read_input answer test </dev/null; [[ $INPUT_EOF == 1 ]]")
        self.shell("confirm <<< n; [[ $MENU_CANCELLED == 1 ]]")

    def test_unknown_service_and_table_are_never_taken_over(self):
        (self.root / 'nftables.service').write_text('[Service]\nExecStart=/usr/sbin/nft -f /etc/nftables.conf\n')
        self.shell('check_unit', ok=False)
        self.shell('config_tool owned "$1"', json.dumps({'nftables': [{'table': {'family': 'ip', 'name': 'nftables'}}]}), ok=False)
        self.shell('config_tool owned "$1"', json.dumps({'nftables': [{'table': {'family': 'ip', 'name': 'nftables', 'comment': 'nftables.sh managed'}}]}))

    def test_list_failure_is_not_treated_as_empty_ruleset(self):
        self.shell('nft() { return 1; }; table_state; [[ $? == 2 ]]')

    def test_stop_only_deletes_owned_table(self):
        self.save()
        self.shell('''check_unit() { :; }; unit_owned() { return 1; }
kernel_lock() { :; }; table_state() { return 0; }
nft() { printf '%s\\n' "$*" >>"$DIR/calls"; }
stop_forwarding
[[ -f $CONF ]] && grep -qx 'delete table ip nftables' "$DIR/calls"
''')

    def test_apply_failure_restores_saved_config_and_actual_table(self):
        self.save()
        previous = self.conf.read_bytes()
        (self.root / 'nftables.nft').write_text('previous saved rules\n')
        self.shell('''config_tool save "$CONF" -1 18081 192.0.2.20 80 tcp new >"$DIR/candidate"
check_ports() { :; }; prepare_service() { :; }; table_state() { return 0; }
nft() { if [[ $1 == list ]]; then echo 'previous live rules'; else return 0; fi; }
systemctl() { [[ $1 == is-active ]] && return 0; return 1; }
load_rules() { cp "$1" "$DIR/restored-live"; }
apply_config "$DIR/candidate"
''', ok=False)
        self.assertEqual(self.conf.read_bytes(), previous)
        self.assertEqual((self.root / 'nftables.nft').read_text(), 'previous saved rules\n')
        self.assertEqual((self.root / 'restored-live').read_text(), 'previous live rules\n')

    def test_busy_port_aborts_before_config_write(self):
        self.save()
        previous = self.conf.read_bytes()
        self.shell('''ss() { echo 'LISTEN 0 128 0.0.0.0:18080'; }
prepare_service() { touch "$DIR/should-not-exist"; }
apply_config "$CONF"
''', ok=False)
        self.assertEqual(self.conf.read_bytes(), previous)
        self.assertFalse((self.root / 'should-not-exist').exists())

    def test_start_can_apply_the_existing_config_file(self):
        self.save()
        previous = self.conf.read_bytes()
        self.shell('''check_ports() { :; }; prepare_service() { :; }; table_state() { return 1; }
nft() { [[ $1 == -c ]]; }
systemctl() { [[ $1 != is-active ]]; }
apply_config "$CONF"
''')
        self.assertEqual(self.conf.read_bytes(), previous)
        self.assertTrue((self.root / 'nftables.nft').exists())

    def test_uninstall_keeps_shared_tools_and_unrecognized_files(self):
        self.save()
        (self.root / 'nftables.service').write_text('# nftables.sh managed\n')
        (self.root / 'nftables').write_text('# nftables.sh managed script\n')
        (self.root / 'nftables.nft').write_text('owned rules')
        (self.root / 'unique.txt').write_text('keep me')
        self.shell('''confirm() { :; }; check_unit() { :; }
systemctl() { printf 'systemctl %s\\n' "$*" >>"$DIR/calls"; }
kernel_lock() { :; }; table_state() { return 0; }
nft() { printf 'nft %s\\n' "$*" >>"$DIR/calls"; }
uninstall
''')
        self.assertTrue((self.root / 'unique.txt').exists())
        self.assertFalse(self.conf.exists())
        self.assertFalse((self.root / 'nftables.service').exists())
        self.assertFalse((self.root / 'nftables').exists())
        calls = (self.root / 'calls').read_text()
        self.assertIn('nft delete table ip nftables', calls)
        self.assertNotIn('flush ruleset', calls)
        self.assertNotIn('remove', calls)


if __name__ == '__main__':
    (PROJECT / '.test-work').mkdir(exist_ok=True)
    unittest.main()

"""Run the real script against a temporary filesystem and mocked system commands.

The test copy has /etc, /sys, /proc, /run and /var redirected; no host settings
or real services are touched. Requires Python 3 and a POSIX shell/coreutils.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'restore-t100-audio.sh'
SH = os.environ.get('TEST_SH') or shutil.which('sh')
if not SH and os.name == 'nt':
    SH = 'C:/Program Files/Git/usr/bin/sh.exe'

def shell_path(path):
    value = str(path).replace('\\', '/')
    if re.match(r'^[A-Za-z]:/', value):
        return '/' + value[0].lower() + value[2:]
    return value

class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='t100-audio-tests-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.posix = shell_path(self.root)
        self.home = self.root / 'home/tester'
        self.home.mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for directory in ('etc/modprobe.d', 'etc/wireplumber/wireplumber.conf.d',
                          'sys/class/dmi/id', 'sys/module/snd_sof/parameters',
                          'proc/asound', 'run/user/1000', 'var/backups'):
            (self.root / directory).mkdir(parents=True)
        self.write('etc/os-release', 'ID=altlinux\n')
        self.write('sys/class/dmi/id/product_name', 'T100TAL\n')
        self.write('sys/module/snd_sof/parameters/sof_debug', '1\n')
        self.write('proc/asound/cards', '1 [rt5640]: SOF - sof-bytcht rt5640\n')
        self.write('run/user/1000/bus', '')
        self.sof = self.root / 'etc/modprobe.d/codex-t100-sof.conf'
        self.wp = self.home / '.config/wireplumber/wireplumber.conf.d/51-codex-t100-alsa.conf'
        source = SCRIPT.read_text(encoding='utf-8')
        for prefix in ('/etc/', '/sys/', '/proc/', '/run/', '/var/'):
            source = source.replace(prefix, self.posix + prefix)
        # A regular fixture replaces the user-bus socket; systemctl is mocked.
        source = source.replace('[ -S ', '[ -e ')
        self.copy = self.root / 'script.sh'
        self.copy.write_text(source, encoding='utf-8', newline='\n')
        self.command('uname', 'case "$1" in -s) echo Linux;; -r) echo test-kernel;; esac')
        self.command('id', 'case "$1" in -u) echo 0;; -un) echo tester;; -gn) echo tester;; *) exit 1;; esac')
        self.command('getent', f'printf "%s\\n" "tester:x:1000:1000:Tester:{self.posix}/home/tester:/bin/sh"')
        self.command('wireplumber', 'echo "wireplumber 0.5.11.1"')
        self.command('pipewire', 'echo "pipewire 1.4.7"')
        self.command('wpctl', 'echo "mock audio status"')
        self.command('sudo', '[ "$1" != -u ] || shift 2; exec "$@"')
        self.command('systemctl', f'printf "%s\\n" "$*" >> "{self.posix}/systemctl.calls"')
        # Retain real install/modes while removing nonexistent fixture owners.
        self.command('install', 'if [ "$1" = -d ]; then shift; [ "$1" != -o ] || shift 4; [ "$1" != -m ] || shift 2; exec mkdir -p "$@"; fi; [ "$1" != -o ] || shift 4; exec /usr/bin/install "$@"')
        self.env = os.environ.copy()
        sep = ';' if os.name == 'nt' else ':'
        coreutils = str(Path(SH).parent) + sep if os.name == 'nt' else ''
        self.env['PATH'] = str(self.bin) + sep + coreutils + self.env.get('PATH', '')
        self.env['MSYS2_ARG_CONV_EXCL'] = '*'
        self.env['HOME'] = str(self.home)

    def write(self, path, content):
        (self.root / path).write_text(content, encoding='utf-8', newline='\n')

    def command(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\nset -eu\n' + body + '\n', encoding='utf-8', newline='\n')
        path.chmod(0o755)

    def run_script(self, *args, success=True):
        result = subprocess.run([SH, shell_path(self.copy), *args, '--user', 'tester'],
                                env=self.env, text=True, encoding='utf-8', errors='replace', capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def snapshots(self):
        return list((self.root / 'var/backups').glob('t100-audio-*'))

    def test_install_and_undo_absent_files(self):
        self.run_script('--install')
        first = self.snapshots()[0]
        self.assertTrue((first / 'sof.absent').exists())
        self.assertTrue((first / 'wireplumber.absent').exists())
        self.assertIn('sof_debug=1', self.sof.read_text())
        self.assertIn('api.alsa.disable-mmap = true', self.wp.read_text())
        self.run_script('--restore', shell_path(first))
        self.assertFalse(self.sof.exists())
        self.assertFalse(self.wp.exists())
        self.assertEqual(len(self.snapshots()), 2)

    def test_restore_existing_settings_exactly(self):
        self.sof.write_text('# Original SOF\n')
        self.wp.parent.mkdir(parents=True)
        self.wp.write_text('# Original user settings\n')
        self.run_script('--install')
        self.run_script('--restore', shell_path(self.snapshots()[0]))
        self.assertEqual(self.sof.read_text(), '# Original SOF\n')
        self.assertEqual(self.wp.read_text(), '# Original user settings\n')

    def test_working_snapshot_restore(self):
        self.run_script('--install')
        self.run_script('--backup')
        good = next(s for s in self.snapshots() if (s / 'sof.conf').exists())
        self.sof.write_text('# changed\n')
        self.wp.write_text('# changed\n')
        self.run_script('--restore', shell_path(good))
        self.assertIn('sof_debug=1', self.sof.read_text())
        self.assertIn('S16LE', self.wp.read_text())

    def test_conflict_does_not_write(self):
        self.write('etc/modprobe.d/other.conf', 'options snd_intel_dspcfg dsp_driver=2\n')
        self.run_script('--install', success=False)
        self.assertFalse(self.sof.exists())
        self.assertEqual(self.snapshots(), [])

    def test_overlapping_wp_rule_does_not_write(self):
        self.write('etc/wireplumber/wireplumber.conf.d/other.conf', 'audio.format = "S32LE"\n')
        self.run_script('--install', success=False)
        self.assertFalse(self.sof.exists())

    def test_corrupted_snapshot_does_not_restore(self):
        self.run_script('--install')
        first = self.snapshots()[0]
        (first / 'user.txt').write_text('tester\nchanged\n')
        before = self.sof.read_bytes()
        self.run_script('--restore', shell_path(first), success=False)
        self.assertEqual(self.sof.read_bytes(), before)
        self.assertEqual(len(self.snapshots()), 1)

    def test_checksum_failure_does_not_restore(self):
        self.run_script('--install')
        first = self.snapshots()[0]
        (first / 'kernel.txt').write_text('modified\n')
        self.run_script('--restore', shell_path(first), success=False)
        self.assertTrue(self.sof.exists())
        self.assertEqual(len(self.snapshots()), 1)

    def test_incomplete_manifest_does_not_restore(self):
        self.run_script('--install')
        first = self.snapshots()[0]
        manifest = first / 'SHA256SUMS'
        manifest.write_text(''.join(manifest.read_text().splitlines(keepends=True)[:-1]))
        self.run_script('--restore', shell_path(first), success=False)
        self.assertEqual(len(self.snapshots()), 1)

    def test_check_is_read_only(self):
        self.run_script('--check')
        self.assertEqual(self.snapshots(), [])
        self.assertFalse(self.sof.exists())
        calls = (self.root / 'systemctl.calls').read_text()
        self.assertNotIn('restart', calls)

    def test_restart_does_not_install(self):
        self.run_script('--restart')
        self.assertFalse(self.sof.exists())
        self.assertEqual(self.snapshots(), [])
        self.assertIn('restart pipewire pipewire-pulse wireplumber', (self.root / 'systemctl.calls').read_text())

    def test_model_guard(self):
        self.write('sys/class/dmi/id/product_name', 'T100TA\n')
        self.run_script('--install', success=False)
        self.assertEqual(self.snapshots(), [])

    def test_missing_session_guard(self):
        (self.root / 'run/user/1000/bus').unlink()
        self.run_script('--install', success=False)
        self.assertEqual(self.snapshots(), [])

    def test_version_guard(self):
        self.command('wireplumber', 'echo "wireplumber 0.4.17"')
        self.run_script('--install', success=False)
        self.assertEqual(self.snapshots(), [])

if __name__ == '__main__':
    if not SH:
        raise SystemExit('POSIX sh not found; set TEST_SH to its executable')
    unittest.main(verbosity=2)

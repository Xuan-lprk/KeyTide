"""Release script contracts. External build/sign/disk tools are synthetic stubs."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
STUB = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(name + ' ' + repr(args) + '\n')
if name == 'git':
    sys.exit('Unexpected Git action')
if name == 'xcodebuild':
    if os.environ.get('FAIL_BUILD') == '1':
        sys.exit(42)
    app = Path(args[args.index('-archivePath') + 1]) / 'Products/Applications/Keytide.app'
    (app / 'Contents/Resources/KeyStatsHelper.app').mkdir(parents=True)
    (app / 'Contents/payload').write_text('same signed app')
elif name == 'ditto':
    if '-c' in args:
        # Assert that ZIP uses the same app that the DMG staging used.
        assert (Path(args[-2]) / 'Contents/payload').read_text() == 'same signed app'
        Path(args[-1]).write_text('zip fixture')
    else:
        shutil.copytree(args[0], args[1])
elif name == 'codesign':
    print('CDHash=' + os.environ.get('HELPER_HASH', 'fixture-hash'), file=sys.stderr)
elif name == 'hdiutil':
    stage = Path(args[args.index('-srcfolder') + 1])
    assert (stage / 'Applications').is_symlink()
    assert (stage / 'Keytide.app/Contents/payload').read_text() == 'same signed app'
    Path(args[-1]).write_text('dmg fixture')
'''


class ReleaseToolingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='keystats-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        for script in ('release.sh', 'build_dmg.sh'):
            shutil.copy2(REPO / 'scripts' / script, self.root / 'scripts' / script)
        for script in ('check_vendored_helper.sh', 'embed_vendored_helper.sh', 'sign_app.sh'):
            p = self.root / 'scripts' / script
            p.write_text('#!/bin/bash\nexit 0\n')
            p.chmod(0o755)
        (self.root / 'Keytide.xcodeproj').mkdir()
        shutil.copy2(REPO / 'Keytide.xcodeproj/project.pbxproj', self.root / 'Keytide.xcodeproj/project.pbxproj')
        (self.root / 'Keytide').mkdir()
        self.write_info(False)
        (self.root / 'vendor').mkdir()
        (self.root / 'vendor/KeyStatsHelper.cdhash.txt').write_text('fixture-hash\n')
        (self.root / 'bin').mkdir()
        for tool in ('xcodebuild', 'ditto', 'codesign', 'hdiutil', 'git'):
            p = self.root / 'bin' / tool
            p.write_text(STUB)
            p.chmod(0o755)
        self.log = self.root / 'commands.log'
        self.env = {**os.environ, 'PATH': str(self.root / 'bin') + ':' + os.environ['PATH'],
                    'COMMAND_LOG': str(self.log), 'KEYSTATS_SYNC_SERVICE_URL': '',
                    'KEYSTATS_RELEASE_VERSION': '', 'FAIL_BUILD': '', 'HELPER_HASH': 'fixture-hash'}

    def write_info(self, enabled):
        with (self.root / 'Keytide/Info.plist').open('wb') as f:
            plistlib.dump({'KeyStatsInAppUpdatesEnabled': enabled, 'SUEnableAutomaticChecks': False}, f)

    def run_script(self, script, *args, **env):
        return subprocess.run(['bash', str(self.root / 'scripts' / script), *args],
                              env={**self.env, **env}, text=True, capture_output=True)

    def commands(self):
        return self.log.read_text() if self.log.exists() else ''

    def test_packaging_preserves_evidence_and_outputs_both_formats(self):
        evidence = self.root / 'build/OtherQA/evidence.txt'
        evidence.parent.mkdir(parents=True)
        evidence.write_text('keep')
        result = self.run_script('build_dmg.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(evidence.read_text(), 'keep')
        output = self.root / 'build/ReleasePackaging/output'
        self.assertEqual({p.name for p in output.iterdir()}, {'Keytide.dmg', 'Keytide.zip', 'SHA256SUMS'})
        check = subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=output, capture_output=True)
        self.assertEqual(check.returncode, 0)
        self.assertEqual(self.commands().count('xcodebuild '), 1)
        self.assertIn("'KEYSTATS_SYNC_SERVICE_URL='", self.commands())
        self.assertNotIn('git ', self.commands())

    def test_build_failure_is_not_retried_or_published(self):
        result = self.run_script('build_dmg.sh', FAIL_BUILD='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands().count('xcodebuild '), 1)
        self.assertNotIn('hdiutil ', self.commands())
        self.assertFalse((self.root / 'build/ReleasePackaging/output').exists())

    def test_helper_identity_mismatch_preserves_previous_artifacts(self):
        old = self.root / 'build/ReleasePackaging/output/Keytide.dmg'
        old.parent.mkdir(parents=True)
        old.write_text('previous release')
        result = self.run_script('build_dmg.sh', HELPER_HASH='changed')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(old.read_text(), 'previous release')
        self.assertNotIn('hdiutil ', self.commands())

    def test_invalid_configuration_fails_before_build(self):
        for env in ({'KEYSTATS_SYNC_SERVICE_URL': 'http://example.com'},
                    {'KEYSTATS_RELEASE_VERSION': '1.2.3;bad'}):
            with self.subTest(env=env):
                self.assertNotEqual(self.run_script('build_dmg.sh', **env).returncode, 0)
        self.write_info(True)
        self.assertNotEqual(self.run_script('build_dmg.sh').returncode, 0)
        self.assertEqual(self.commands(), '')

    def test_optional_production_url_and_version_are_passed(self):
        result = self.run_script('build_dmg.sh', KEYSTATS_SYNC_SERVICE_URL='https://own.workers.dev',
                                 KEYSTATS_RELEASE_VERSION='2.0.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("'KEYSTATS_SYNC_SERVICE_URL=https://own.workers.dev'", self.commands())
        self.assertIn("'MARKETING_VERSION=2.0.0'", self.commands())

    def test_version_preparation_only_changes_main_app_metadata(self):
        import re
        p = self.root / 'Keytide.xcodeproj/project.pbxproj'
        original = p.read_text()
        result = self.run_script('release.sh', '2.0.0-beta.1')
        self.assertEqual(result.returncode, 0, result.stderr)
        pattern = r'buildSettings = \{.*?\n\t\t\t\};'
        old_blocks = re.findall(pattern, original, re.S)
        new_blocks = re.findall(pattern, p.read_text(), re.S)
        changed = 0
        for old, new in zip(old_blocks, new_blocks):
            if 'INFOPLIST_FILE = Keytide/Info.plist;' in old:
                changed += 1
                number = int(re.search(r'CURRENT_PROJECT_VERSION = (\d+);', old)[1])
                self.assertIn(f'CURRENT_PROJECT_VERSION = {number + 1};', new)
                self.assertIn('MARKETING_VERSION = 2.0.0;', new)
            else:
                self.assertEqual(old, new)
        self.assertEqual(changed, 2)
        self.assertEqual(self.commands(), '')
        prepared = p.read_bytes()
        self.assertNotEqual(self.run_script('release.sh', 'invalid').returncode, 0)
        self.assertEqual(prepared, p.read_bytes())


if __name__ == '__main__':
    unittest.main()

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / 'apps/android/src/io/github/weqdevs/remote'


class ConnectionLayoutTests(unittest.TestCase):
    def test_insets_use_shared_compatibility_entry(self):
        source = (ANDROID / 'MainActivity.java').read_text()
        self.assertEqual(source.count('WindowInsetsHelper.contentInsets(insets)'), 3)
        self.assertNotIn('WindowInsets.Type.', source)

    def test_details_are_in_menus_not_home_footer(self):
        ios = (ROOT / 'apps/ios/Sources/WeQRemoteApp.swift').read_text()
        dock = ios.split('@ViewBuilder private var dock:', 1)[1].split('private var canPair:', 1)[0]
        self.assertNotIn('versionInfo', dock)
        self.assertNotIn('tailscaleStatus', dock)
        self.assertIn('model.showingDetails = true', ios)
        self.assertIn('Toggle("检查测试版"', ios)
        self.assertIn('Label(model.checkingUpdates', ios)
        android = (ANDROID / 'MainActivity.java').read_text()
        self.assertNotIn('dock.addView(networkState', android)
        self.assertIn('more.setOnClickListener(view -> showDetailsMenu())', android)
        self.assertIn('prerelease.setText("检查测试版")', android)
        self.assertIn('Text(warning.message)', ios)
        self.assertIn('连接已中断，正在重连…', android)
        health = (ROOT / 'apps/ios/Sources/ConnectionHealth.swift').read_text()
        self.assertIn('连接已中断，正在重连…', health)
        self.assertIn('网络已断开，恢复后自动重连', health)
        self.assertIn('main.postDelayed(reconnectPoll, 15000)', android)
        self.assertIn('health.failed()', android)
        self.assertIn('health.succeeded(', android)

    def test_android_content_can_outgrow_viewport(self):
        source = (ANDROID / 'MainActivity.java').read_text()
        self.assertIn('scroll.setFillViewport(true)', source)
        self.assertIn('scroll.addView(content, new android.widget.ScrollView.LayoutParams(-1, -2))', source)
        self.assertIn('content.addView(hero, new LinearLayout.LayoutParams(-1, -2, 1f))', source)
        self.assertIn('input.addView(pairButton, new LinearLayout.LayoutParams(dp(48), dp(48)))', source)

    def test_ios_scroll_type_and_hit_target(self):
        source = (ROOT / 'apps/ios/Sources/WeQRemoteApp.swift').read_text()
        self.assertIn('ScrollView {', source)
        self.assertNotIn('.scrollDisabled(true)', source)
        for text in ['Text("WeQ Remote")', 'Text(statusText)', 'Text(heroTitle)', 'Text(code)',
                     'Text("扫码连接")', 'Text(model.isConnecting ? "停止" : "连接")']:
            font = source.split(text, 1)[1].split('.font(', 1)[1].split('\n', 1)[0]
            self.assertNotIn('.system(size:', font, text)
        field = source.split('private var linkField:', 1)[1].split('private var reconnectRow:', 1)[0]
        self.assertIn('.font(.body)', field)
        self.assertIn('.frame(width: 44, height: 44)\n                        .contentShape(Rectangle())', field)

    def test_saved_computer_actions_and_update_do_not_repair(self):
        ios = (ROOT / 'apps/ios/Sources/WeQRemoteApp.swift').read_text()
        row = ios.split('private var reconnectRow:', 1)[1].split('private func pair()', 1)[0]
        self.assertLess(row.index('qrcode.viewfinder'), row.index('Text(model.isConnecting'))
        self.assertLess(row.index('Text(model.isConnecting'), row.index('"trash"'))
        self.assertNotIn('.disabled(model.busy', row)
        model = (ROOT / 'apps/ios/Sources/RemoteModel.swift').read_text()
        update = model.split('private func updateConnection()', 1)[1].split('private func waitForApproval', 1)[0]
        self.assertIn('probe: .status, token: saved.token', update)
        self.assertNotIn('"v1/pair"', update)
        self.assertNotIn('SavedConnection.delete', update)
        android = (ANDROID / 'MainActivity.java').read_text()
        update = android.split('private void updateConnection(Invitation link)', 1)[1].split('private String routeFailureMessage', 1)[0]
        self.assertIn('token = credential', update)
        self.assertIn('updatingConnection = true; verify()', update)
        self.assertNotIn('claim(link)', update)
        self.assertNotIn('ConnectionStore.delete', update)
        self.assertIn('retryButton.setText(isConnecting() ? "停止" : "连接")', android)
        self.assertIn('if (isConnecting()) { reconnectPaused = true; stopNetwork(true); }', android)

    @unittest.skipUnless(shutil.which('javac') and shutil.which('java'), '需要 JDK')
    def test_insets_on_legacy_runtime_without_api30_classes(self):
        # 编译实际 helper，再从 JVM 类路径删除新 API，验证旧分支不会链接它们。
        sources = {
            'android/annotation/TargetApi.java': '''package android.annotation;
public @interface TargetApi { int value(); }''',
            'android/os/Build.java': '''package android.os;
public class Build { public static class VERSION { public static int SDK_INT; } }''',
            'android/graphics/Rect.java': '''package android.graphics;
public class Rect {
 public final int left, top, right, bottom;
 public Rect(int l, int t, int r, int b) { left=l; top=t; right=r; bottom=b; }
}''',
            'android/graphics/Insets.java': '''package android.graphics;
public class Insets {
 public final int left=11, top=22, right=33, bottom=300;
}''',
            'android/view/WindowInsets.java': '''package android.view;
public class WindowInsets {
 public int getSystemWindowInsetLeft() { return 1; }
 public int getSystemWindowInsetTop() { return 2; }
 public int getSystemWindowInsetRight() { return 3; }
 public int getSystemWindowInsetBottom() { return 4; }
 public android.graphics.Insets getInsets(int mask) {
  if (mask != 3) throw new AssertionError("system bars and IME must both be requested");
  return new android.graphics.Insets();
 }
 public static class Type {
  public static int systemBars() { return 1; }
  public static int ime() { return 2; }
 }
}''',
            'io/github/weqdevs/remote/InsetsProbe.java': '''package io.github.weqdevs.remote;
public class InsetsProbe {
 public static void main(String[] args) {
  android.os.Build.VERSION.SDK_INT = Integer.parseInt(args[0]);
  android.graphics.Rect r = WindowInsetsHelper.contentInsets(new android.view.WindowInsets());
  boolean modern = android.os.Build.VERSION.SDK_INT >= 30;
  if (r.left != (modern ? 11 : 1) || r.top != (modern ? 22 : 2)
   || r.right != (modern ? 33 : 3) || r.bottom != (modern ? 300 : 4))
   throw new AssertionError("wrong insets");
 }
}''',
        }
        with tempfile.TemporaryDirectory(prefix='insets-', dir=ROOT / 'tests') as directory:
            base = Path(directory)
            files = []
            for name, source in sources.items():
                path = base / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source)
                files.append(str(path))
            classes = base / 'classes'
            subprocess.run(['javac', '--release', '8', '-d', str(classes),
                            str(ANDROID / 'WindowInsetsHelper.java'), *files], check=True)
            command = ['java', '-cp', str(classes), 'io.github.weqdevs.remote.InsetsProbe']
            for api in [30, 36]:
                subprocess.run([*command, str(api)], check=True)
            for name in ['android/graphics/Insets.class', 'android/view/WindowInsets$Type.class',
                         'io/github/weqdevs/remote/WindowInsetsHelper$Api30.class']:
                (classes / name).unlink()
            # 用只含旧方法的 WindowInsets 替换编译桩，而不只删除 Type。
            legacy = base / 'android/view/WindowInsets.java'
            legacy.write_text(sources['android/view/WindowInsets.java'].split(' public android.graphics.Insets', 1)[0] + '}')
            subprocess.run(['javac', '--release', '8', '-d', str(classes), str(legacy)], check=True)
            for api in [26, 28, 29]:
                subprocess.run([*command, str(api)], check=True)


if __name__ == '__main__':
    unittest.main()

# CLAUDE.md

macOS メニューバーアプリ **MenubarCC**（Swift / AppKit, arm64, Developer ID 署名 + Apple 公証）。Claude Code の各セッション状態をメニューバーのカニ「Clawd」で表示する。

## Source

- `Sources/*.swift` — メニューバーアプリ本体（Swift / AppKit）。6 ファイル構成：
  - `main.swift` — エントリポイント。NSApplication を accessory として起動。
  - `AppDelegate.swift` — NSStatusItem・メニュー・アニメーション・更新確認・設定 UI。
  - `SessionMonitor.swift` — `~/.claude/sessions/*.json` からセッション状態を読み込み。
  - `FrameGenerator.swift` — カニ PNG から walk/bounce/pulse/static アニメーションフレームを CoreGraphics で生成。
  - `HookManager.swift` — Claude Code フックの install/uninstall、JSON 設定ファイル I/O。
  - `UpdateChecker.swift` — GitHub releases からバージョンチェック、DMG ダウンロード、自動更新。
- `menubarcc_hook.py` — Claude Code のフックブリッジ。`~/.claude/sessions/<sid>.waiting` フラグの維持、効果音再生（`muteAll`）、バナー通知イベントのスプール書き出し（`bannersEnabled`、`events/` ディレクトリ経由でアプリが消費して UNUserNotificationCenter で表示）。アプリ起動時にインストール済みスクリプトを自動更新。
- `build.sh` — ビルド・署名スクリプト。

セッション状態は `status`（busy/idle）と `.waiting` フラグ、経過時間から導出する：**waiting**＝idle かつ `.waiting` あり、**stuck**＝busy かつ閾値超え（`stuckSecs`、既定600s、検出は `stuckEnabled` でON/OFF）、**idle**＝idle かつ `.waiting` なし。

### 旧 Python 版（レガシー、v1.x）

- `menubarcc.py` — 旧メニューバーアプリ本体（rumps / py2app）。v2.0 で Swift に完全リライト。
- `setup.py` — 旧 py2app ビルド設定。
- `native_launcher.m` — macOS 26 対応の試作ネイティブランチャー（不要、Swift リライトで解決）。

## Build & Release

ビルドに必要なのは Xcode Command Line Tools のみ（Python / conda 不要）。

```sh
./build.sh 2.0.0    # → dist/MenubarCC.app
```

リリース手順：

1. **バージョン更新** — `build.sh` の引数（`./build.sh X.Y.Z`）。バージョンは完全な `X.Y.Z` 形式。
2. **ビルド** — `./build.sh X.Y.Z` → `dist/MenubarCC.app`。
3. **スモークテスト** — `dist/MenubarCC.app/Contents/MacOS/MenubarCC` を数秒起動してクラッシュなし確認。
4. **公証** — 下記参照。
5. **DMG** — 下記参照。
6. **push & release** — `git push origin main` 後に `gh release create vX.Y.Z ./MenubarCC-X.Y.Z.dmg --repo ksterx/MenubarCC --title "MenubarCC vX.Y.Z" --target main --notes "..."`。

### ⚠️ Bundle ID は `com.ksterx.clawd`

macOS 26 (Tahoe) の Liquid Glass メニューバーは、NSStatusItem の位置をバンドル ID 単位でキャッシュする。旧 Python 版 (`com.ksterx.MenubarCC`) が不可視スロットにキャッシュされたため、Swift v2 では `com.ksterx.clawd` に変更。元に戻すとアイコンが消える。

### ⚠️ DMG はステージングフォルダから作る（`-srcfolder dist/MenubarCC.app` は禁止）

`.app` 単体から DMG を作ると「Applications へドラッグ」のインストール UI が消える（**v1.5.0 でこの退行が発生**）。正しい DMG は **3 つ**を含む：`MenubarCC.app` / `Applications -> /Applications` シンボリックリンク / アイコン配置用の `.DS_Store`。

```sh
STAGING=$(mktemp -d)
cp -R dist/MenubarCC.app "$STAGING/MenubarCC.app"
ln -s /Applications "$STAGING/Applications"
cp <layout>/.DS_Store "$STAGING/.DS_Store"
hdiutil create -volname MenubarCC -srcfolder "$STAGING" -ov -format UDZO MenubarCC-<ver>.dmg
```

作成後は必ずマウントして `Applications` リンク・`.DS_Store`・`.app` の 3 つが揃っているか検証する。

### 署名 + 公証（必須・スキップ厳禁）

`build.sh` が Developer ID 署名まで行う。公証は別途：

```sh
IDENTITY="Developer ID Application: Kosuke Ishikawa (44UPBHBKJV)"

# 公証 → staple
ditto -c -k --keepParent dist/MenubarCC.app /tmp/MenubarCC.zip
xcrun notarytool submit /tmp/MenubarCC.zip --keychain-profile menubarcc --wait
xcrun stapler staple dist/MenubarCC.app

# DMG 署名 → 公証 → staple
codesign --force --sign "$IDENTITY" --timestamp MenubarCC-X.Y.Z.dmg
xcrun notarytool submit MenubarCC-X.Y.Z.dmg --keychain-profile menubarcc --wait
xcrun stapler staple MenubarCC-X.Y.Z.dmg

# 最終確認
spctl --assess --type execute --verbose=2 dist/MenubarCC.app
spctl --assess --type open --context context:primary-signature -v MenubarCC-X.Y.Z.dmg
```

公証用 App-Specific Password は keychain profile `menubarcc` に保存済み（`xcrun notarytool store-credentials menubarcc --apple-id ... --team-id 44UPBHBKJV` で登録）。

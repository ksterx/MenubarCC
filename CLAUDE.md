# CLAUDE.md

macOS メニューバーアプリ **MenubarCC**（rumps / py2app, arm64, Developer ID 署名 + Apple 公証）。Claude Code の各セッション状態をメニューバーのカニで表示する。

## Source

- `cc_menubar.py` — メニューバーアプリ本体（rumps）。セッション状態の判定・描画・メニュー・更新確認。
- `menubarcc_hook.py` — Claude Code のフックブリッジ。`~/.claude/sessions/<sid>.waiting` フラグの維持と効果音再生。
- `setup.py` — py2app ビルド設定（バージョン・同梱 dylib）。

セッション状態は `status`（busy/idle）と `.waiting` フラグ、経過時間から導出する：**waiting**＝idle かつ `.waiting` あり、**stuck**＝busy かつ閾値超え（`stuckSecs`、既定600s、検出は `stuckEnabled` でON/OFF）、**idle**＝idle かつ `.waiting` なし。

## Build & Release

ビルド環境は `~/.conda/envs/menubarcc-build`（conda-forge python 3.13 + py2app/rumps/pyobjc/pillow/certifi）。`<envpy>` = `~/.conda/envs/menubarcc-build/bin/python`。

リリース手順：

1. **バージョン更新** — `setup.py` の `CFBundleVersion` と `CFBundleShortVersionString` の**両方**を完全な `X.Y.Z` に。短縮版を `1.6` 等にすると更新確認のバージョン比較が壊れる。
2. **ビルド** — `rm -rf build dist; <envpy> setup.py py2app` → `dist/MenubarCC.app`。
3. **DMG**（下記の注意を厳守）。
4. **スモークテスト** — `dist/MenubarCC.app/Contents/MacOS/MenubarCC` を数秒起動して生存確認（クラッシュ・traceback なし）＋同梱 python (`Contents/MacOS/python`) で SSL→GitHub 疎通確認。
5. **push & release** — `git push origin main` 後に `gh release create v<ver> ./MenubarCC-<ver>.dmg --repo ksterx/claude-code-menubar --title "MenubarCC v<ver>" --target main --notes "..."`。

### ⚠️ DMG はステージングフォルダから作る（`-srcfolder dist/MenubarCC.app` は禁止）

`.app` 単体から DMG を作ると「Applications へドラッグ」のインストール UI が消える（**v1.5.0 でこの退行が発生**。v1.4.0 以前は出ていた）。正しい DMG は **3 つ**を含む：`MenubarCC.app` / `Applications -> /Applications` シンボリックリンク / アイコン配置用の `.DS_Store`。

```sh
STAGING=$(mktemp -d)
cp -R dist/MenubarCC.app "$STAGING/MenubarCC.app"
ln -s /Applications "$STAGING/Applications"
cp <layout>/.DS_Store "$STAGING/.DS_Store"   # 一度 v1.4.0 の DMG から抽出。ボリューム名 "MenubarCC" と項目名が同一なので再適用される
hdiutil create -volname MenubarCC -srcfolder "$STAGING" -ov -format UDZO MenubarCC-<ver>.dmg
```

作成後は必ずマウントして `Applications` リンク・`.DS_Store`・`.app` の 3 つが揃っているか検証する。

### ⚠️ libexpat を同梱する（さもないと起動時クラッシュ）

conda-forge の `pyexpat.so` は `@rpath/libexpat.1.dylib` をリンクするが py2app は自動で含めない。未同梱だと起動時に `import plistlib` で `Symbol not found: _XML_SetHashSalt16Bytes` で落ちる。`setup.py` の `frameworks` に `libffi`/`libssl`/`libcrypto` と並べて `libexpat.1.dylib` を入れる（既設定済み）。

### 署名 + 公証（必須・スキップ厳禁）

未署名/アドホックの DMG を配布すると、ダウンロード経由の起動時に **「Apple could not verify "MenubarCC.app" is free of malware」** で Gatekeeper に弾かれる。v1.5.0 / v1.6.0 で実際に発生した。Public repo に出す前に下記を必ず通す:

```sh
IDENTITY="Developer ID Application: Kosuke Ishikawa (44UPBHBKJV)"

# 1. ビルド直後の rpath 修正対象は4つ
#    _ctypes/_ssl/_hashlib/pyexpat — それぞれ libffi/libssl/libcrypto/libexpat を参照
#    libssl 自身も @rpath/libcrypto を引くので付け替え必須
install_name_tool -change @rpath/libffi.8.dylib    @executable_path/../Frameworks/libffi.8.dylib    "$(find dist/MenubarCC.app -name '_ctypes*.so' | head -1)"
install_name_tool -change @rpath/libssl.3.dylib    @executable_path/../Frameworks/libssl.3.dylib    "$(find dist/MenubarCC.app -name '_ssl*.so'    | head -1)"
install_name_tool -change @rpath/libcrypto.3.dylib @executable_path/../Frameworks/libcrypto.3.dylib "$(find dist/MenubarCC.app -name '_ssl*.so'    | head -1)"
install_name_tool -change @rpath/libcrypto.3.dylib @executable_path/../Frameworks/libcrypto.3.dylib "$(find dist/MenubarCC.app -name '_hashlib*.so'| head -1)"
install_name_tool -change @rpath/libcrypto.3.dylib @executable_path/../Frameworks/libcrypto.3.dylib  dist/MenubarCC.app/Contents/Frameworks/libssl.3.dylib
install_name_tool -change @rpath/libexpat.1.dylib  @executable_path/../Frameworks/libexpat.1.dylib  "$(find dist/MenubarCC.app -name 'pyexpat*.so' | head -1)"

# 2. inside-out 署名（--options runtime --timestamp 必須。--deep は不可）
find dist/MenubarCC.app \( -name '*.so' -o -name '*.dylib' \) -type f -print0 \
  | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$IDENTITY" "{}"
for fw in dist/MenubarCC.app/Contents/Frameworks/*.dylib; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$fw"
done
# Contents/MacOS/ には MenubarCC 本体に加えて `python` も居る。両方署名すること
for f in dist/MenubarCC.app/Contents/MacOS/*; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$f"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" dist/MenubarCC.app

# 3. 公証 → staple
ditto -c -k --keepParent dist/MenubarCC.app /tmp/MenubarCC.zip
xcrun notarytool submit /tmp/MenubarCC.zip --keychain-profile menubarcc --wait
xcrun stapler staple dist/MenubarCC.app

# 4. DMG も同様に署名 → 公証 → staple
codesign --force --sign "$IDENTITY" --timestamp MenubarCC-X.Y.Z.dmg
xcrun notarytool submit MenubarCC-X.Y.Z.dmg --keychain-profile menubarcc --wait
xcrun stapler staple MenubarCC-X.Y.Z.dmg

# 最終確認
spctl --assess --type execute --verbose=2 dist/MenubarCC.app   # → source=Notarized Developer ID
spctl --assess --type open --context context:primary-signature -v MenubarCC-X.Y.Z.dmg
```

公証用 App-Specific Password は keychain profile `menubarcc` に保存済み（`xcrun notarytool store-credentials menubarcc --apple-id ... --team-id 44UPBHBKJV` で登録）。

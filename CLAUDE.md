# CLAUDE.md

macOS メニューバーアプリ **MenubarCC**（rumps / py2app, arm64, 未署名）。Claude Code の各セッション状態をメニューバーのカニで表示する。

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

### 署名について

アプリは未署名/アドホック。署名は初回起動時の Gatekeeper「開発元が確認できません」警告に効くもので、**DMG のインストール UI とは無関係**。インストール UI が出ない問題は必ず上記 DMG レイアウトを疑う。

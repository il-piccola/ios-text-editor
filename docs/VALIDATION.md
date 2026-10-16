# 検証記録

最新結果（2026-10-16）：MacでNode119件、Native55件が成功。Xcode 27.1（27A9275）、iOS 27.1 Simulatorで署名なしDebugテストとReleaseビルドが成功しました。MacのNodeは24.21.0、Windowsの先行Node119件成功は別実行です。

## 実行コマンド

リポジトリのルートで実行します。外部Node packageのインストールは不要です。

```sh
node --test Tests/core.test.cjs Tests/merge.test.cjs Tests/replacement.test.cjs Tests/reload.test.cjs Tests/data-preservation.test.cjs Tests/capacity.test.cjs
node Tools/audit-project.cjs
git diff --check
xcodebuild -version
xcrun simctl list devices available
xcodebuild -project IyoEditor.xcodeproj -scheme IyoEditor -configuration Debug \
  -destination 'platform=iOS Simulator,id=<利用可能な専用SimulatorのID>' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
xcodebuild -project IyoEditor.xcodeproj -scheme IyoEditor -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedDataRelease CODE_SIGNING_ALLOWED=NO build
```

Simulator IDは各環境で確認します。実行ログとxcresultには端末・パス等が含まれるため公開しません。結果は各コマンドの終了コード0と成功サマリーで確認しました。DerivedDataとテスト結果はGit除外対象です。

## 確認した範囲

| 試験 | 結果と限界 |
| --- | --- |
| Node | 119件成功・失敗0。保存状態、通知順、三原文保全、容量・履歴、置換、Unicode・改行。偽保存先での試験です。 |
| Native | 55件成功・失敗0。Swift/JavaScriptCore、DraftStore、UITextView Undo/Redo、20,000件置換の先行入力保持、ローカルTempのFiles試験等。 |
| 画面寸法 | 390pt標準文字と320ptアクセシビリティ文字、実UIWindowScene接続で保存状態を切替。本文ビューの位置・寸法・選択・スクロール・本文保持を確認。修正前は高さが約35〜181pt変化し、2試験13アサーションが失敗しました。 |
| 本文再代入 | 保存状態のみ8回更新し、ビュー生成1回、text/attributedText/選択/スクロール/focus/fontへの追加書込み0回。実IME入力中の試験ではありません。 |
| 保存アイコン | 待機・保護・書込状態の描画PNG一致、44pt以上の領域、busy中のaction呼出し0回、IME・競合・結果不明・ロック拒否を確認。初回action到達も検査。 |
| 再読込アイコン | 待機/書込のPNG一致、44pt領域、busy/IME/ロック/保存先なしの拒否と競合・結果不明時の既存確認経路へのaction到達を検査。本文を扱う既存reload処理は変更なし。 |
| 重複保存 | 遅延write中に8回saveを呼び、operation全体と受付版が不変。終了後に本文一致。偽プロバイダの冪等化だけで判定していません。 |
| ビルド | 署名なしSimulatorのDebug test buildとRelease build成功。実機署名ビルドの代替ではありません。 |
| 静的監査 | project参照、Swift/JS収録、共有scheme、UTF-8、相対リンク、同梱許諾を確認。コンパイラの代替ではありません。 |

## 当日の問題と修正

初回環境準備ではXcodeのライセンス・セットアップが不足し、ユーザーによる設定後にCLI検証を再開しました。代理の規約同意はしていません。サンドボックス内のCoreSimulator接続制限は、承認されたCLI実行で対応しました。

共有schemeの余分な空白、取消クロージャの型推論、テストによるUIKit Undoグループの強制終了、原子保存後のURL resource cacheによるidentity誤拒否を修正。最初のNative47件成功後、画面移動の回帰2件、通常表示と本文再代入防止2件、保存アイコンと重複保存防止3件を追加し、54件になりました。さらに再読込アイコン回帰1件を追加して55件です。実装一覧は[引継ぎ](CONTINUATION-REVIEW.md)を参照してください。

独立したコードレビュー・テスト計画を実施しました。最終保存ボタン差分に修正必須指摘はありません。ユーザーは大きい保存ボタンの有効/無効切替がちらつき原因と実機で特定しました。修正版では通常busyで外観を変えず、内部ガードで処理中のタップを無害に扱います。

## 未検証と手動確認

実機起動と日本語入力はユーザー報告で確認済みですが、最新の保存・再読込アイコン修正は未インストール・未確認です。GUIの繰り返し操作承認を避け、実機は手動確認へ切り替えました。実機の変更・既存下書きへの試験は行っていません。

実キーボードのIME変換・取消・再変換、長文性能、強制終了後の保持、低容量時の動作、実Files/Google Drive、本番クラウド反映は未確認です。Filesは既定無効を維持しています。SimulatorのFiles試験はローカル一時ファイルのみです。保存アイコン更新後の入力、連打、初回保存先選択、Undo/Redoをテスト文で確認することが次の段階です。

## 公開用ツリーの追加検証

コミット予定のindexを別の一時フォルダへ展開し、ローカルの署名設定・Info.plist変更を含まない汎用projectでも、同じ署名無効コマンドでNative55件成功・失敗0とReleaseビルド成功を確認しました。公開対象17ファイルは独立レビューでも秘密情報・個人識別情報の混入なしと確認しました。公開ツリー全体のUUID検出は既存のNodeテスト用ID定数であり、端末IDではありません。個別ログや端末IDはコミットしません。

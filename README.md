# iOS Text Editor

日本語の文章編集と、端末下書き・ファイル保存の状態を分けて扱うiPhone用テキストエディタの初期プロトタイプです。

**Xcode 27.1で署名なしSimulatorのDebug/ReleaseビルドとNativeTests 55件が成功しています。実機起動と日本語入力はユーザー報告で確認済みですが、最新の保存・再読込アイコン修正は実機未確認です。実Files/Google Drive保存も未検証です。** 通常の保存先には、アプリ内の検証用プロバイダを使用します。Files接続はソース実装済みですが、既定では無効です。新規・別名保存のFiles対応はありません。

作業を再開する場合は、まず[開発引継ぎ](docs/CONTINUATION-REVIEW.md)を読んでください。現在の制限、当日の変更、次の確認事項をまとめています。

## 機能と構成

- `Editor/`：UITextViewによる入力・選択・Undoの単一所有。一括文字列置換の件数・候補確認と受付上限。
- `Core/`：NodeとiOS JavaScriptCoreで共用する保存状態、三方向比較、履歴・容量判定。
- `Storage/`：端末下書きの原子保存、検証用プロバイダ、Filesのbookmark・identity・coordination・変更通知。
- `UI/`：日本語UI、最近のファイル、保存先と名前、下書き保護版と書込み受付版、履歴閲覧・明示削除・復元。
- `App/`：Swift/JS接続と操作の実行。保存完了で編集中の本文を差し戻しません。

保存失敗・取消・結果不明でも下書きを残します。同名衝突や外部変更を確認せず上書きしません。Filesの書込み受付をクラウド反映完了とは表示しません。設計と制約は[アーキテクチャ](docs/ARCHITECTURE.md)を参照してください。

## 共通ロジックの確認

WindowsではNode.js 22、MacではNode.js 24.21.0で検証しました。外部packageのインストールは不要です。

```sh
node --test Tests/core.test.cjs Tests/merge.test.cjs Tests/replacement.test.cjs Tests/reload.test.cjs Tests/data-preservation.test.cjs Tests/capacity.test.cjs
node Tools/audit-project.cjs
```

必要な場合は`node Tools/generate-project.cjs`でXcode projectを再生成できます。この処理はprojectと共有schemeを置き換えるため、手動で変更した設定は事前に確認してください。

試験区分は[検証状況](docs/VALIDATION.md)、ビルドと実機確認は[Mac手順](docs/MAC-VALIDATION.md)、権利の扱いは[LICENSES.md](LICENSES.md)に記載しています。

認証情報、秘密鍵、個人原稿、端末下書き、bookmarkなどの実データをこのリポジトリに保存しないでください。実データを使う検証は、リポジトリ外の別フォルダで行ってください。

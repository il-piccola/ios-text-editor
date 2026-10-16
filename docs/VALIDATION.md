# 検証状況

共通JavaScriptのNode試験と、Swift/iOS側の試験は分けて扱います。

2026-10-16に公開用コピーでNode試験を実行し、119件成功・失敗0件、exit 0を確認しました。project収録・参照・UTF-8・相対リンク・Edhita許諾の静的監査と、Info.plist・共有schemeのXML読込も成功しました。

Node試験は本番の`SessionCore.js`、`MergeCore.js`、`CapacityPolicy.js`、`ReplacementPlan.js`を直接読み込みます。合計119件で、保存状態、通知順、三原文保全、容量・履歴、置換、Unicode・改行を対象とします。保存先はテスト用の偽プロバイダで、下書きの書込みはテスト用Tempを使用します。

これらの成功はSwift DraftStore、JavaScriptCore、UIKit、実機IME/Undo、Files/Driveの成功を意味しません。NativeTests47メソッドは作成済みですが、未コンパイル・未実行です。Xcode project読込、iOS build、実iPhone、実Files/Drive、クラウド反映、実機メモリ測定は未検証です。

`Tools/audit-project.cjs`はproject参照、Swift/JS収録、UTF-8、相対リンク、同梱許諾を読み取り検査します。Xcodeのparserやcompilerの代替ではありません。

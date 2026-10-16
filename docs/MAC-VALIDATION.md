# Macでのビルドと実機確認

必要な環境は、iOS 17以上のSDKとiPhone Simulatorを含むXcodeです。projectはiOS deployment target 17.0、Swift 5モード、iPhone向けです。共有schemeは`IyoEditor`です。Command Line Tools単独ではUIKit/iOSアプリを検証できません。

最初に利用可能な環境を確認します。

```sh
sw_vers
xcodebuild -version
xcrun swift --version
xcodebuild -showsdks
xcodebuild -project IyoEditor.xcodeproj -list
```

署名なしのSimulator buildから始めます。

```sh
xcodebuild -project IyoEditor.xcodeproj -scheme IyoEditor -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project IyoEditor.xcodeproj -scheme IyoEditor -showdestinations
```

存在するSimulatorのIDを確認した後、そのIDを指定します。

```sh
xcodebuild -project IyoEditor.xcodeproj -scheme IyoEditor -configuration Debug \
  -destination 'platform=iOS Simulator,id=<確認したID>' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Release buildも別に行います。NativeTestsは47メソッドのソースがありますが、まだコンパイル・実行していません。Swift/JavaScriptCoreのJSON接続、文字コード、下書きepoch、容量failure、原本保持、保存中追記、遅い通知、履歴復元、Filesのlocal temp試験を確認してください。

実iPhoneでは次を確認します。Simulator成功を実機合格とは扱いません。

- 日本語フリック・ローマ字入力の変換、確定、取消、選択中操作、OSが提供する再変換。
- 入力と一括置換・履歴復元のUndo/Redo。結合文字、emoji、ZWJ、raw Unicodeの保持。
- 狭い画面、横向き、keyboard、Dynamic Type、VoiceOver。
- 長文の入力遅延、scroll、選択、peak memory、置換上限での全文拒否。
- 保存連打、保存中追記、再起動・強制終了、低空き容量、破損下書き。
- Files有効化を別変更としてレビュー後、「このiPhone内」でscope・coordination・bookmark・identity・監視解放を確認。
- 実Driveを扱う段階で認証と保存範囲を決め、通信断、移動・削除、他端末更新、サーバー反映を個別に確認。

projectの署名は無効です。実機起動では適切なbundle ID・team・署名の設定が別途必要です。資格情報や署名ファイルをcommitしないでください。実原稿・端末データの試験はリポジトリ外で行ってください。

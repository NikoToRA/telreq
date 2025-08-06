# Telreq - AI通話録音・転写アプリ

音声通話を自動で録音・転写し、AI要約とTODO抽出を行うiOSアプリです。

## 🌟 特徴

- **🤖 AI自動要約**: Azure OpenAI + ローカル処理によるハイブリッドAI
- **🎯 リアルタイム転写**: iOS Speech Framework + Azure Speech Service
- **📱 標準電話アプリ統合**: CallKitによるシームレスな連携
- **⚡ 自動録音**: 着信・発信時の自動録音開始
- **💾 オフライン対応**: ネットワーク不安定時のローカル処理
- **🔐 セキュリティ**: エンドツーエンド暗号化対応
- **📊 履歴管理**: 通話履歴とデータ管理

## 📞 標準電話アプリとの統合

### ✅ 完全両立
Telreqは**CallKit**と**AVAudioSession**を使用して、iOSの標準電話アプリと完全に両立します。

### 🚀 動作フロー

#### 📞 着信時（自動録音）
1. **着信検知** → CallKitが自動検知
2. **権限確認** → マイク・音声認識権限チェック  
3. **録音開始** → バックグラウンドで自動録音
4. **通話終了** → 自動で録音停止・AI処理実行
5. **結果表示** → 要約・TODO・履歴保存

#### 📱 発信時（事前録音）
1. **録音準備** → Telreqで録音ボタンタップ
2. **発信** → 標準電話アプリで発信
3. **統合録音** → 通話全体を録音
4. **自動処理** → 終了時にAI処理・保存

### 🔧 技術的な両立性

- **CallKit統合**: システムレベルでの通話状態監視
- **共有AudioSession**: 音声リソースの適切な管理  
- **非侵入的設計**: 標準アプリの動作を妨げない
- **権限ベース動作**: 必要最小限の権限のみ使用

## 🛠 セットアップ

### 1. 必要な権限
```xml
<!-- Info.plist に追加 -->
<key>NSMicrophoneUsageDescription</key>
<string>通話録音機能に使用します</string>
<key>NSSpeechRecognitionUsageDescription</key>  
<string>音声のテキスト化に使用します</string>
```

### 2. Azure設定（オプション）
```swift
// Configuration/Production/AzureOpenAI.plist
endpoint = "your-azure-openai-endpoint"
apiKey = "your-api-key"
deploymentName = "your-deployment-name"
```

### 3. 使用開始
1. **権限許可**: マイク・音声認識権限を許可
2. **バックグラウンド録音**: 設定で有効化
3. **通話監視**: アプリ内で通話監視をON
4. **普通に通話** → 自動で録音・転写開始

## 🏗 アーキテクチャ

### コアコンポーネント
- **CallManager**: CallKit統合・通話状態管理
- **AudioCaptureService**: 音声録音・品質監視
- **SpeechRecognitionService**: iOS + Azure音声認識
- **TextProcessingService**: Azure OpenAI要約・TODO抽出
- **OfflineDataManager**: ローカルデータ管理・同期

### データフロー
```
通話開始 → 音声録音 → 音声認識 → AI処理 → 要約・TODO → 履歴保存
    ↓         ↓         ↓        ↓       ↓
  CallKit  AudioCapture  Speech   OpenAI  Storage
```

## 💡 メモリ最適化

- **自動切り替え**: メモリ150MB超でローカル処理に切り替え
- **クリーンアップ**: 強制ガベージコレクション・キャッシュクリア
- **監視機能**: リアルタイムメモリ使用量監視

## ⚠️ 注意事項

### 法的・プライバシー
- **録音告知**: 相手方への録音告知を推奨
- **企業利用**: コンプライアンス規定の確認必須
- **データ保護**: プライベート通話の適切な管理

### 技術的制限
- **権限必須**: マイク・音声認識権限がないと動作不可
- **バックグラウンド**: iOS制限により処理時間に制約
- **ネットワーク**: AI処理にはインターネット接続推奨

## 📁 プロジェクト構成

```
Telreq/
├── Models/           # データモデル・プロトコル
├── Services/         # 音声・AI・ストレージサービス  
├── ViewModels/       # MVVM ViewModels
├── Views/            # SwiftUI Views
├── Config/           # Azure・API設定
└── Documentation/    # API・アーキテクチャドキュメント
```

## 🚀 ビルド・実行

```bash
# Xcode でプロジェクトを開く
open Telreq.xcodeproj

# シミュレーター or 実機でビルド・実行
⌘ + R
```

## 🔍 トラブルシューティング

### 録音されない
1. **権限確認**: 設定 > プライバシー > マイク > Telreq ✓
2. **音声認識**: 設定 > プライバシー > 音声認識 > Telreq ✓  
3. **バックグラウンド**: 設定 > Telreq > バックグラウンド更新 ✓

### 処理が重い
1. **メモリ不足** → アプリ再起動
2. **ネットワーク遅延** → WiFi/LTE確認
3. **AI処理** → ローカル処理モードに切り替え

## 📋 TODO・改善計画

- [ ] リアルタイム転写UI改善
- [ ] 話者識別機能追加
- [ ] 複数言語対応
- [ ] Apple Watch連携
- [ ] Siri Shortcuts対応

## 🤝 コントリビューション

1. Fork the Project
2. Create Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit Changes (`git commit -m 'Add AmazingFeature'`)
4. Push to Branch (`git push origin feature/AmazingFeature`)
5. Open Pull Request

## 📄 ライセンス

MIT License - 詳細は `LICENSE` ファイルを確認

## 📞 サポート

- **Issues**: GitHub Issues で技術的問題を報告
- **Documentation**: `Documentation/` フォルダの詳細ガイド
- **Logs**: アプリ内デバッグログ機能を活用

---

**Telreq** - あなたの通話をスマートに記録・管理する次世代AIアプリ
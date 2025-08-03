# TelreqApp - iPhone電話自動文字起こし・要約アプリ

## プロジェクト概要

TelreqAppは、iPhoneで通話内容を自動的に文字起こしし、要約・保存するiOSネイティブアプリケーションです。

### 主要機能

1. **リアルタイム音声転写**: iOS Speech Framework（優先）とGoogle Speech-to-Text API（フォールバック）
2. **自動要約生成**: 通話内容の重要ポイント抽出
3. **クラウドストレージ**: Azure Blob Storageでの安全なデータ保存
4. **共有機能**: ユーザー間での通話記録共有
5. **プライバシー保護**: エンドツーエンド暗号化

### 技術制約への対応

- **iOS通話録音制限**: スピーカーフォン+マイク録音方式を採用
- **App Store承認**: プライバシー規制とAppleガイドラインに完全準拠
- **リアルタイム処理**: 低遅延での音声処理とUIフィードバック

## プロジェクト構造

```
TelreqApp/
├── Sources/
│   ├── Core/               # コアビジネスロジック
│   ├── Features/          # 機能別モジュール
│   ├── Services/          # 外部サービス連携
│   ├── UI/                # ユーザーインターフェース
│   └── Extensions/        # CallKit Extension等
├── Tests/
│   ├── Unit/              # ユニットテスト
│   ├── Integration/       # 統合テスト
│   └── UI/                # UIテスト
├── Resources/
│   ├── Assets/            # アセット・画像
│   └── Localization/      # 多言語対応
├── Documentation/
│   ├── API/               # API仕様書
│   ├── Architecture/      # アーキテクチャ設計
│   └── Deployment/        # デプロイメント手順
└── Configuration/
    ├── Development/       # 開発環境設定
    ├── Production/        # 本番環境設定
    └── Staging/          # ステージング環境設定
```

## 開発フェーズ

### Phase 1: MVP（基本転写機能）
- スピーカーフォン音声キャプチャ
- iOS Speech Framework統合
- 基本的なUI実装

### Phase 2: クラウド統合
- Azure Blob Storage連携
- 要約機能実装
- データ暗号化

### Phase 3: 共有機能
- ユーザー認証システム
- 通話記録共有機能
- プライバシー制御

### Phase 4: 最適化・拡張
- パフォーマンス最適化
- 追加言語サポート
- エンタープライズ機能

## 要件と制約

詳細な要件定義は `.kiro/specs/phone-call-transcription/` ディレクトリを参照してください。

## セットアップ

（開発環境のセットアップ手順は後で追加予定）

## ライセンス

（ライセンス情報は後で追加予定）
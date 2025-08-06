# Azure API設定ガイド

このドキュメントでは、TelreqアプリでAzure APIを使用するための設定手順を説明します。

## 必要なAzureサービス

1. **Azure Storage Account** - 音声ファイルとテキストデータの保存
2. **Azure Speech Service** - 音声認識
3. **Azure OpenAI Service** - テキスト要約とAI処理

## 設定手順

### 1. Azure Storage Accountの設定

1. Azure Portalで新しいストレージアカウントを作成
2. アクセスキーを取得
3. 接続文字列を取得（形式：`DefaultEndpointsProtocol=https;AccountName=youraccount;AccountKey=yourkey;EndpointSuffix=core.windows.net`）

### 2. Azure Speech Serviceの設定

1. Azure PortalでSpeech Serviceリソースを作成
2. リージョンを選択（推奨：japaneast）
3. キーとエンドポイントを取得

### 3. Azure OpenAI Serviceの設定

1. Azure PortalでOpenAI Serviceリソースを作成
2. デプロイメントを作成（推奨：gpt-4o）
3. キーとエンドポイントを取得

## 環境変数の設定

開発環境で以下の環境変数を設定してください：

```bash
export AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=your-account;AccountKey=YOUR_STORAGE_KEY;EndpointSuffix=core.windows.net"
export AZURE_SPEECH_SUBSCRIPTION_KEY="YOUR_SPEECH_SUBSCRIPTION_KEY"
export AZURE_OPENAI_API_KEY="YOUR_OPENAI_API_KEY"
export AZURE_OPENAI_ENDPOINT="https://your-endpoint.openai.azure.com/"
```

## Xcodeでの設定

1. Xcodeでプロジェクトを開く
2. Product > Scheme > Edit Scheme
3. Run > Arguments > Environment Variables
4. 上記の環境変数を追加

## 設定の確認

アプリを起動すると、コンソールに以下のようなログが表示されます：

```
Azure Configuration Status:
- Storage: Configured
- Speech: Configured
- OpenAI: Configured
- OpenAI Endpoint: Configured
All Azure services are properly configured
```

## トラブルシューティング

### よくある問題

1. **権限エラー**: Azureリソースのアクセス権限を確認
2. **ネットワークエラー**: ファイアウォール設定を確認
3. **認証エラー**: APIキーが正しく設定されているか確認

### デバッグ方法

1. Xcodeのコンソールでログを確認
2. Azure Portalでリソースの使用状況を確認
3. ネットワーク接続をテスト

## セキュリティ注意事項

- APIキーは絶対にソースコードに直接記述しないでください
- 本番環境では、Key Vaultなどのセキュアな方法でキーを管理してください
- 環境変数は適切に暗号化して管理してください

## サポート

設定に問題がある場合は、以下を確認してください：

1. Azure Portalでのリソース設定
2. ネットワーク接続
3. APIキーの有効性
4. リージョン設定の一貫性 
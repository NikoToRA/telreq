# API仕様書

## エンドポイント一覧

### 1. 音声処理API

#### 音声アップロード
```
POST /api/v1/audio/upload
Content-Type: multipart/form-data

Parameters:
- audio_file: binary (音声ファイル)
- metadata: json (通話メタデータ)
- user_id: string (ユーザーID)

Response:
{
  "session_id": "uuid",
  "upload_url": "string",
  "status": "uploading|completed|failed"
}
```

#### リアルタイム転写開始
```
POST /api/v1/transcription/start
Content-Type: application/json

Request:
{
  "session_id": "uuid",
  "language": "ja|en|auto",
  "quality": "standard|high",
  "real_time": true
}

Response:
{
  "transcription_id": "uuid",
  "websocket_url": "wss://...",
  "estimated_completion": "2024-01-01T10:00:00Z"
}
```

#### 転写結果取得
```
GET /api/v1/transcription/{transcription_id}

Response:
{
  "transcription_id": "uuid",
  "status": "processing|completed|failed",
  "text": "string",
  "confidence": 0.95,
  "segments": [
    {
      "start_time": 0.0,
      "end_time": 5.2,
      "text": "こんにちは",
      "confidence": 0.98,
      "speaker_id": "speaker_1"
    }
  ],
  "metadata": {
    "language_detected": "ja",
    "audio_duration": 120.5,
    "processing_time": 15.2
  }
}
```

### 2. 要約生成API

#### 要約作成
```
POST /api/v1/summary/generate
Content-Type: application/json

Request:
{
  "transcription_id": "uuid",
  "summary_type": "brief|detailed|bullet_points",
  "language": "ja|en",
  "focus_areas": ["key_decisions", "action_items", "participants"]
}

Response:
{
  "summary_id": "uuid",
  "summary": "string",
  "key_points": ["point1", "point2"],
  "action_items": ["action1", "action2"],
  "participants": ["person1", "person2"],
  "tags": ["business", "meeting"],
  "confidence": 0.87
}
```

### 3. データ管理API

#### 通話記録保存
```
POST /api/v1/calls
Content-Type: application/json

Request:
{
  "transcription_id": "uuid",
  "summary_id": "uuid",
  "call_metadata": {
    "start_time": "2024-01-01T10:00:00Z",
    "end_time": "2024-01-01T10:15:00Z",
    "participant_number": "+8190XXXXXXXX",
    "call_direction": "incoming|outgoing",
    "audio_quality": "excellent|good|fair|poor"
  },
  "privacy_settings": {
    "is_shareable": true,
    "retention_days": 365,
    "encryption_level": "standard|high"
  }
}

Response:
{
  "call_id": "uuid",
  "azure_blob_url": "string",
  "encryption_key_id": "string",
  "created_at": "2024-01-01T10:15:30Z"
}
```

#### 通話履歴取得
```
GET /api/v1/calls?page=1&limit=20&date_from=2024-01-01&date_to=2024-01-31

Response:
{
  "calls": [
    {
      "call_id": "uuid",
      "start_time": "2024-01-01T10:00:00Z",
      "duration": 900,
      "participant_number": "+8190XXXXXXXX",
      "summary_preview": "重要な会議について...",
      "tags": ["business", "important"],
      "is_shared": false,
      "audio_available": true
    }
  ],
  "pagination": {
    "current_page": 1,
    "total_pages": 5,
    "total_records": 95
  }
}
```

### 4. 共有機能API

#### 共有リクエスト送信
```
POST /api/v1/sharing/request
Content-Type: application/json

Request:
{
  "call_id": "uuid",
  "recipient_user_id": "uuid",
  "message": "会議の記録を共有します",
  "permission_level": "read|read_write",
  "expiry_date": "2024-02-01T00:00:00Z"
}

Response:
{
  "sharing_request_id": "uuid",
  "status": "pending",
  "expires_at": "2024-01-08T10:00:00Z"
}
```

#### 共有承認/拒否
```
PUT /api/v1/sharing/request/{sharing_request_id}
Content-Type: application/json

Request:
{
  "action": "accept|reject",
  "message": "承認しました"
}

Response:
{
  "sharing_id": "uuid",
  "status": "active|rejected",
  "shared_call_id": "uuid"
}
```

### 5. ユーザー管理API

#### ユーザー登録
```
POST /api/v1/users/register
Content-Type: application/json

Request:
{
  "email": "user@example.com",
  "password": "string",
  "phone_number": "+8190XXXXXXXX",
  "display_name": "山田太郎",
  "privacy_consent": true,
  "terms_accepted": true
}

Response:
{
  "user_id": "uuid",
  "access_token": "jwt_token",
  "refresh_token": "refresh_token",
  "expires_in": 3600
}
```

## エラーレスポンス

### 標準エラー形式
```json
{
  "error": {
    "code": "TRANSCRIPTION_FAILED",
    "message": "音声認識に失敗しました",
    "details": "Audio quality too low for transcription",
    "timestamp": "2024-01-01T10:00:00Z",
    "request_id": "uuid"
  }
}
```

### エラーコード一覧

| コード | HTTPステータス | 説明 |
|--------|---------------|------|
| AUDIO_UPLOAD_FAILED | 400 | 音声ファイルのアップロードに失敗 |
| TRANSCRIPTION_FAILED | 422 | 音声認識処理に失敗 |
| INSUFFICIENT_AUDIO_QUALITY | 422 | 音声品質が不十分 |
| STORAGE_QUOTA_EXCEEDED | 413 | ストレージ容量上限超過 |
| UNAUTHORIZED | 401 | 認証情報が無効 |
| FORBIDDEN | 403 | 操作権限なし |
| NOT_FOUND | 404 | リソースが見つからない |
| RATE_LIMIT_EXCEEDED | 429 | レート制限超過 |
| INTERNAL_SERVER_ERROR | 500 | サーバー内部エラー |

## 認証・認可

### JWT認証
すべてのAPIエンドポイントはJWT Bearer tokenによる認証が必要です。

```
Authorization: Bearer <jwt_token>
```

### APIキー認証（管理用API）
```
X-API-Key: <api_key>
```

## レート制限

| エンドポイント | 制限 |
|---------------|------|
| 音声アップロード | 30 requests/min |
| 転写処理 | 10 requests/min |
| API全般 | 1000 requests/hour |

## WebSocket接続（リアルタイム転写）

### 接続URL
```
wss://api.telreq.com/v1/transcription/realtime?token=<jwt_token>
```

### メッセージ形式

#### 音声データ送信
```json
{
  "type": "audio_chunk",
  "session_id": "uuid",
  "data": "base64_encoded_audio",
  "chunk_index": 1,
  "timestamp": "2024-01-01T10:00:00Z"
}
```

#### 転写結果受信
```json
{
  "type": "transcription_result",
  "session_id": "uuid",
  "text": "こんにちは",
  "is_final": false,
  "confidence": 0.95,
  "timestamp": "2024-01-01T10:00:01Z"
}
```
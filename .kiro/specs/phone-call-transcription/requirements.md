# Requirements Document

## Introduction

iPhoneで電話がかかってきた際に自動的に起動し、通話内容を文字起こしして要約・保存するアプリケーションです。通話終了後、自動的に文字起こしされた内容がアプリ内に蓄積され、ユーザーが後から確認できる機能を提供します。文字起こしにはiPhoneの純正機能を優先的に使用し、必要に応じてGoogle Speech-to-TextなどのWebサービスも検討します。

## Requirements

### Requirement 1

**User Story:** 電話ユーザーとして、電話がかかってきた時に自動的にアプリが起動してほしい、手動でアプリを開く手間を省くため

#### Acceptance Criteria

1. WHEN 着信があった時 THEN システムは自動的にアプリを起動する SHALL
2. WHEN アプリが起動した時 THEN システムは通話の録音準備を開始する SHALL
3. IF ユーザーが通話を拒否した場合 THEN システムはアプリを終了する SHALL

### Requirement 2

**User Story:** 電話ユーザーとして、通話中の音声を自動的に文字起こししてほしい、後から内容を確認できるため

#### Acceptance Criteria

1. WHEN 通話が開始された時 THEN システムはリアルタイムで音声を文字起こしする SHALL
2. WHEN 文字起こしを実行する時 THEN システムは最初にiPhone純正のSpeech Recognition機能を使用する SHALL
3. IF iPhone純正機能で精度が不十分な場合 THEN システムはGoogle Speech-to-Text APIを使用する SHALL
4. WHEN 文字起こし中にエラーが発生した時 THEN システムはユーザーに通知し、代替手段を提案する SHALL

### Requirement 3

**User Story:** 電話ユーザーとして、通話が終了したら自動的に内容を要約してほしい、長い通話でも重要なポイントを素早く把握するため

#### Acceptance Criteria

1. WHEN 通話が終了した時 THEN システムは自動的に文字起こし内容を要約する SHALL
2. WHEN 要約を生成する時 THEN システムは重要なキーワードと主要な話題を抽出する SHALL
3. WHEN 要約が完成した時 THEN システムは要約をアプリ内に保存する SHALL
4. IF 通話時間が5分未満の場合 THEN システムは要約せずに全文を保存する SHALL

### Requirement 4

**User Story:** 電話ユーザーとして、通話データを構造化してAzure Blob Storageに保存したい、クラウドで安全に管理し、どこからでもアクセスできるため

#### Acceptance Criteria

1. WHEN 通話が終了した時 THEN システムは音声データをAzure Blob Storageに保存する SHALL
2. WHEN 文字起こしが完了した時 THEN システムはテキストデータをAzure Blob Storageに保存する SHALL
3. WHEN データを保存する時 THEN システムは構造化されたメタデータ（日時、相手番号、要約等）を含む SHALL
4. WHEN ユーザーがアプリを開いた時 THEN システムはAzure Blob Storageから通話記録一覧を取得し表示する SHALL
5. IF ネットワーク接続がない場合 THEN システムはローカルに一時保存し、接続回復時に同期する SHALL

### Requirement 5

**User Story:** 電話ユーザーとして、過去の通話記録をアプリ内で確認したい、いつでも通話内容を振り返ることができるため

#### Acceptance Criteria

1. WHEN ユーザーがアプリを開いた時 THEN システムは過去の通話記録一覧を表示する SHALL
2. WHEN 通話記録を表示する時 THEN システムは日時、相手の電話番号、要約を含む SHALL
3. WHEN ユーザーが特定の記録を選択した時 THEN システムは詳細な文字起こし内容を表示する SHALL
4. WHEN ユーザーが検索機能を使用した時 THEN システムは通話内容から関連する記録を検索する SHALL

### Requirement 6

**User Story:** 電話ユーザーとして、プライバシーとセキュリティが保護されていてほしい、個人情報が適切に管理されるため

#### Acceptance Criteria

1. WHEN 通話データを保存する時 THEN システムはデータを暗号化して保存する SHALL
2. WHEN 外部APIを使用する時 THEN システムはユーザーの同意を事前に取得する SHALL
3. WHEN ユーザーがデータ削除を要求した時 THEN システムは指定された記録を完全に削除する SHALL
4. IF アプリがアンインストールされた場合 THEN システムは全ての保存データを削除する SHALL

### Requirement 7

**User Story:** 電話ユーザーとして、同じアプリを使用している相手と通話記録を共有したい、お互いの理解を深め、記録の精度を向上させるため

#### Acceptance Criteria

1. WHEN 同じアプリユーザー同士が通話した時 THEN システムは通話記録共有の可否を確認する SHALL
2. WHEN 両者が共有に同意した時 THEN システムは双方の文字起こし結果を統合する SHALL
3. WHEN 共有記録を表示する時 THEN システムは発言者を区別して表示する SHALL
4. WHEN 共有記録に差異がある時 THEN システムはより精度の高い記録を優先する SHALL
5. IF 一方が共有を拒否した場合 THEN システムは個別の記録のみを保存する SHALL

### Requirement 8

**User Story:** 電話ユーザーとして、アプリの設定をカスタマイズしたい、自分の使用パターンに合わせて調整するため

#### Acceptance Criteria

1. WHEN ユーザーが設定画面を開いた時 THEN システムは文字起こし方法の選択肢を表示する SHALL
2. WHEN ユーザーが自動起動設定を変更した時 THEN システムは設定を保存し適用する SHALL
3. WHEN ユーザーが要約の詳細レベルを設定した時 THEN システムは設定に応じて要約を生成する SHALL
4. WHEN ユーザーがAzure接続設定を行う時 THEN システムは認証情報を安全に保存する SHALL
5. IF ユーザーが特定の番号を除外設定した場合 THEN システムはその番号からの着信時に起動しない SHALL
# SSLVPNAutoConnect

FortiClient の GUI には自動ログインがないため、[openfortivpn](https://github.com/adrienverge/openfortivpn) を使って SSL-VPN に自動接続する macOS メニューバーアプリです。

## 機能

- メニューバーからワンクリック接続 / 切断
- VPN ユーザー名・パスワードを macOS Keychain に安全に保管
- 起動時の自動接続
- ログイン項目への登録（macOS 13+）
- 切断後の自動再接続（`persistent` オプション）
- FortiGate の証明書ピン留め（`trusted-cert`）

## 前提条件

```bash
brew install openfortivpn
```

openfortivpn は PPP トンネルを作成するため **管理者権限（sudo）** が必要です。接続時に macOS の管理者パスワード入力ダイアログが表示されます。

### パスワード入力を省略する（任意）

毎回管理者パスワードを入力したくない場合、`/etc/sudoers.d/openfortivpn` を作成します:

```bash
sudo visudo -f /etc/sudoers.d/openfortivpn
```

```
YOUR_USERNAME ALL=(ALL) NOPASSWD: /opt/homebrew/bin/openfortivpn
```

Intel Mac の場合はパスが `/usr/local/bin/openfortivpn` になることがあります。

## ビルド

```bash
./scripts/build.sh
```

または Xcode で `VPNAutoConnect.xcodeproj` を開いてビルドします。

ビルド成果物:

```
build/Build/Products/Release/SSLVPNAutoConnect.app
```

## 使い方

1. `SSLVPNAutoConnect.app` を起動（Applications などにコピー推奨）
2. メニューバーの盾アイコン → **Settings…**
3. 以下を入力:
   - **Host**: VPN ゲートウェイ（例: `vpn.example.com`）
   - **Port**: 通常 `443`
   - **Username** / **Password**
4. **Save** をクリック（認証情報は Keychain に保存されます）
5. **Connect automatically on launch** を有効にすると、次回起動から自動接続
6. **Connect** をクリック → 管理者パスワードを入力

## 証明書フィンガープリントの取得

FortiGate の SSL 証明書 SHA256 を取得するには:

```bash
openssl s_client -connect vpn.example.com:443 </dev/null 2>/dev/null \
  | openssl x509 -outform PEM \
  | openssl dgst -sha256
```

出力例:

```
SHA256(stdin)= e46d4aff08ba6914e64daa85bc6112a422fa7ce16631bff0b592a28556f993db
```

Settings の **Trusted certificate SHA256** には `e46d4aff...` の部分（`SHA256(stdin)=` 以降）を入力します。

## 設定ファイルの保存場所

| 項目 | パス |
|------|------|
| アプリ設定（ホスト等） | UserDefaults |
| VPN ユーザー名・パスワード | Keychain (`vpn-username`, `vpn-password`) |
| 実行時 openfortivpn 設定 | `~/Library/Application Support/SSLVPNAutoConnect/openfortivpn.conf` |
| 接続ログ | `~/Library/Application Support/SSLVPNAutoConnect/openfortivpn.log` |

ユーザー名・パスワードは UserDefaults には保存されません。Keychain 属性は `AfterFirstUnlockThisDeviceOnly` です。

接続中のみ openfortivpn 設定ファイルにパスワードが書き込まれ、ファイル権限は `600` です。切断時に削除されます。

## アーキテクチャ

```
MenuBarExtra (SwiftUI)
    └── VPNManager
            ├── CredentialStore → KeychainService
            ├── ConfigWriter → openfortivpn.conf
            └── AppleScript (admin) → openfortivpn プロセス起動
```

## 制限事項

- **2FA / OTP**: 現バージョンでは未対応。FortiToken 等が必須の環境では使えません
- **SAML 認証**: 未対応（openfortivpn の `--saml-login` は将来対応可能）
- **管理者権限**: 接続のたびに（または sudoers 設定後は不要に）管理者認証が必要

## ライセンス

MIT

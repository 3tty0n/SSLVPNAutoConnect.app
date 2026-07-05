# SSL-VPN Auto Connect

This is a macOS GUI helper to automate SSL-VPN-login by using [openfortivpn](https://github.com/adrienverge/openfortivpn).

## Prerequisite

```bash
brew install openfortivpn
```


Since openfortivpn makes a PPP tunnel, this app needs `sudo`, so a dialogue to
enter your root password when connecting to the SSL-VPN server.

### Skip entering password (not mandatory)

Make `/etc/sudoers.d/openfortivpn`:

```bash
sudo visudo -f /etc/sudoers.d/openfortivpn
```

```
YOUR_USERNAME ALL=(ALL) NOPASSWD: /opt/homebrew/bin/openfortivpn
```

## Build

```bash
./scripts/build.sh
```

Result:

```
build/Build/Products/Release/SSLVPNAutoConnect.app
```

## How to use

1. Launch `SSLVPNAutoConnect.app` (you should copy the app to `/Applications`)
2. Open **Settings…**
3. Enter the following infromation:
   - **Host**: VPN gateway（例: `vpn.example.com`）
   - **Port**: Normally `443`
   - **Username** / **Password**
4. Click **Save** (credentials are saved in Keychain)
5. If you enable **Connect automatically on launch**, you can automatically
   connect to the gateway
6. Click **Connect**  and enter root password

## How to get fingerprint for FortiGate


```bash
openssl s_client -connect vpn.example.com:443 </dev/null 2>/dev/null \
  | openssl x509 -outform PEM \
  | openssl dgst -sha256
```

Example:

```
SHA256(stdin)= e46d4aff08ba6914e64daa85bc6112a422fa7ce16631bff0b592a28556f993db
```

## Limitations

- **2FA / OTP**: Currently unsupported.
- **SAML**: Cunnrently unsupported.

## License

MIT

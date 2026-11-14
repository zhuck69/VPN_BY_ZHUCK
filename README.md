# ZHUCK VPN — self-hosted public installer

Этот пакет разворачивает отдельный VPN на VPS пользователя. Он не подключается к инфраструктуре ZHUCK VPN и не содержит production-ключей, токенов или готовых ссылок.

После установки сервер сам генерирует новые UUID, Reality-ключи, пароли Hysteria2 и QR-коды. Пользователь вводит только свои данные VPS.

Это одно-VPS/один комплект учётных данных. Публичного multi-user бота, общей базы подписок и панели выдачи в пакете нет: для нескольких пользователей создавайте отдельные учётные данные и не раздавайте одну сгенерированную ссылку всем.

## Что нужно пользователю

- чистый Ubuntu 22.04/24.04 или Debian 12/13;
- root или SSH-пользователь с `sudo`;
- открытые TCP/UDP-порты 443 и UDP 20000–50000;
- SSH-ключ на локальном компьютере.

## Windows

```powershell
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Deploy-To-VPS.ps1 `
  -Server 203.0.113.10 `
  -User root `
  -IdentityFile C:\Users\you\.ssh\id_ed25519
```

Если SSH-адрес отличается от публичного адреса VPS:

```powershell
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Deploy-To-VPS.ps1 `
  -Server ssh.example.net `
  -PublicAddress 203.0.113.10 `
  -IdentityFile C:\Users\you\.ssh\id_ed25519
```

## Linux/macOS

```bash
chmod 700 install.sh
scp -i ~/.ssh/id_ed25519 install.sh root@203.0.113.10:/tmp/zhuck-install.sh
ssh -i ~/.ssh/id_ed25519 root@203.0.113.10 \
  'chmod 700 /tmp/zhuck-install.sh && sudo /tmp/zhuck-install.sh --server-address 203.0.113.10'
```

## Результат

На VPS появятся:

- `/root/happ-vpn/subscription.txt` — импортируемая подписка;
- `/root/happ-vpn/INSTALL_REPORT.txt` — локальный отчёт;
- QR-коды для VLESS Reality и Hysteria2;
- резерв предыдущих конфигураций в `/root/happ-vpn/backups/`.

Ссылки из `INSTALL_REPORT.txt` нельзя публиковать открыто: они дают доступ к этому VPS. Для общего доступа используйте собственную подписочную страницу и отдельные учётные данные на каждого пользователя.

## Проверка

```bash
systemctl is-active xray hysteria-server happ-vpn-udp-hop
ss -lntup | grep ':443'
```

Поддерживаемые клиенты: HAPP, INCY, v2rayNG, Hiddify и совместимые Xray-клиенты. Этот пакет не обещает обход любой фильтрации: доступность зависит от сети, IP VPS и правил оператора.

## Безопасность

Не вставляйте в публичный репозиторий `.env`, `INSTALL_REPORT.txt`, приватные ключи, UUID, пароли Hysteria2, QR-коды или готовые VLESS/Hysteria2-ссылки. Для каждого VPS запускайте установщик отдельно.

IAS: Служба ідентифікації та авторизації
========================================

IAS (Identity and Authorization Service) — служба керування цифровими ідентичностями, сертифікатами, політиками безпеки та рішеннями авторизації для інфраструктури Zencrypted.

Система використовується як адміністративна консоль для роботи з користувачами, пристроями, сертифікатами, профілями безпеки, VPN-сервісами та графом відносин між ними.

IAS не є VPN-сервером і не є центром сертифікації. IAS координує життєвий цикл ідентичностей, політик і сертифікатів, тоді як CA відповідає за підписування сертифікатів, а VPN-сервіси використовують результати авторизації.

Запуск
------

```bash
$ rebar3 get-deps
$ rebar3 shell
$ open http://localhost:8041/app/index.htm
```

Архітектурна модель
-------------------

Security Profile
  -> Claims
      -> Certificate
          -> Authorization

IAS відповідає за:

- керування ідентичностями;
- керування політиками безпеки;
- життєвий цикл сертифікатів;
- аудит;
- рішення авторизації.

Центр сертифікації (CA) відповідає за підписування сертифікатів.
VPN використовує сертифікати та результати авторизації, підготовлені через IAS.

VPN provisioning delivery
-------------------------

IAS формує канонічні revisioned provisioning commands і доставляє їх до
VPN runtime через configurable distributed Erlang RPC. Поточний напрямок
інтеграції односторонній: `IAS -> VPN`; VPN не викликає IAS під час handshake,
peer runtime або dataplane processing, а виконує вже доставлений стан локально.

Окремі IAS і VPN ноди є поточною development topology, а не постійною
архітектурною вимогою. У майбутньому VPN може бути доданий як dependency і
OTP application до одного IAS release, при цьому provisioning contract,
ownership model та напрямок `IAS -> VPN` мають залишитися незмінними. Деталі
flow, runtime boundary, deployment modes, transport configuration, normalized
statuses, retry semantics, cookie/node naming, and development startup steps are
documented in `docs/IAS-VPN-PROVISIONING-DELIVERY.md`.

Керування ключами
-----------------

У production-моделі приватний ключ належить пристрою.

Device
  -> Generate Key Pair
      -> CSR
          -> IAS
              -> CA
                  -> Certificate

Пристрій генерує пару ключів локально та передає до CA лише CSR. Приватний ключ не покидає пристрій і не зберігається в IAS.

Device-bound OVPN provisioning
------------------------------

Поточний live-runtime wizard реалізує production-aligned device-bound flow:

```text
Prepare Device key/CSR plan
  -> run generated script on Device
      -> keys/<unique>.key
      -> <unique>.csr
  -> upload CSR only
  -> CMP enrollment through external CA
  -> validate certificate public key and CA chain
  -> update Device private-key reference
  -> assemble OVPN with public CA/client PEM and `key keys/<unique>.key`
```

Згенерований shell script створює каталог `keys/`, генерує новий ключ
`secp384r1`, відмовляється перезаписувати наявний key/CSR та перевіряє CSR
перед завантаженням. IAS зберігає лише безпечний відносний key reference,
CSR/certificate fingerprints і lineage metadata. Тіло приватного ключа ніколи
не передається IAS і не вбудовується в `.ovpn`.

Наскрізний flow перевірено локально: SHA-256 public key, отриманого з
Device private key, збігається з SHA-256 public key у CMP-issued certificate.
Для імпорту готовий `.ovpn` має бути доступний разом із відносним каталогом
`keys/`, на який посилається директива `key`.

Життєвий цикл
-------------

IAS моделює такі процеси:

- імпорт і аналіз VPN-конфігурацій;
- enrollment сертифікатів;
- випуск сертифікатів;
- перевірку сертифікатів;
- заміну сертифікатів;
- відкликання сертифікатів;
- аналіз готовності пристроїв;
- аналіз довіри та авторизації.

Ролі
----

IAS орієнтований на адміністраторів, операторів безпеки та аудиторів.

Користувацький портал, якщо буде потрібний, має бути окремим спрощеним інтерфейсом поверх тієї ж моделі.

Автори
-------

* Максим Сохацький
* Юрій Масловський

## IAS to VPN Common Test

The IAS repository contains an opt-in Common Test suite that starts a real VPN
node from a separate checkout and verifies the revisioned IAS provisioning
lifecycle over distributed Erlang RPC.

By default, the suite expects the repositories to be siblings:

```text
../ias
../vpn
```

The VPN checkout can be selected explicitly with `VPN_REPO`:

```bash
VPN_REPO=/absolute/path/to/vpn \
  rebar3 ct --suite test/ias_vpn_rpc_SUITE
```

The suite prepares the VPN debug OVPN identity, compiles the VPN debug profile
once, then starts `vpn_ct@127.0.0.1` directly from the compiled debug code path
without invoking a second `rebar3` build, and verifies:

- the initial upsert is applied and starts the peer;
- the repeated revision is unchanged;
- disable stops the peer;
- enable starts it again;
- revoke stops and locks the peer;
- enable after revoke is rejected;
- the IAS and runtime certificate fingerprints match;
- a mismatched IAS certificate fingerprint is rejected before a peer starts;
- a stale provisioning revision is rejected without rolling the runtime state
  back or restarting the peer;
- an IAS-provisioned `client_a` sends a deterministic payload through the real
  encrypted UDP dataplane to `peer_b`, with payload, digest, epoch, sequence,
  and duplicate-count assertions;
- authenticated rekey advances both peers to the next key epoch while dataplane
  payload delivery continues before and after the key transition;
- a supervised `client_a` peer restart produces a new process, re-establishes
  the authenticated session, preserves the provisioning revision, and restores
  dataplane payload delivery without another IAS provisioning command;
- replaying the exact retained encrypted frame increments duplicate and replay
  drop counters while the plaintext payload remains recorded only once;
- the previous receive-key epoch remains recognized during its grace window,
  expires on schedule, and is then rejected as a stale epoch without delivering
  the retained plaintext a second time;
- rejected guard checks are retained in the IAS delivery history;
- the IAS delivery history does not contain private key, OVPN, session-key, or
  ECDH material.

The test uses the fixed debug TUN interfaces and UDP ports from the VPN debug
configuration. Stop any manually running `vpn@127.0.0.1` node before running
the suite. The VPN process log is written under
`_build/test/logs/ias_vpn_rpc/vpn.log`.

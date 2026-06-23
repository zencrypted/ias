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

IAS формує канонічні revisioned provisioning commands і може доставляти їх до
VPN runtime через configurable distributed Erlang RPC. Деталі flow, transport
configuration, normalized statuses, retry semantics, cookie/node naming, and
development startup steps are documented in
`docs/IAS-VPN-PROVISIONING-DELIVERY.md`.

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

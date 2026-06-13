IAS: Identity, Access and Security Administration
================================================

IAS is an Erlang/N2O bootstrap application for Identity, Access and Security Administration.

IAS was forked from FIN.
Inherited FIN/BPE pages are intentionally removed from the visible UI.
IAS v0 starts with placeholder pages for Users, Devices, Services, Certificates and Security Profiles.


Запуск
------

IAS bootstrap currently provides a placeholder Erlang/N2O application shell.

IAS bootstrap currently uses Mnesia-backed KVS.
RocksDB is disabled temporarily for Ubuntu 20.04 compatibility.

```
$ rebar3 get-deps
$ rebar3 shell
$ open http://localhost:8041/app/index.htm
```

IAS Domain Model v0
-------------------

Users
Devices
Services
Certificates
Security Profiles

Current implementation uses hardcoded demo data.
Persistence and CA integration will be added later.

IAS Relationship Model
----------------------

User
  -> Device
      -> Certificate
      -> Service

VPN integration will consume these relationships later.

Relationships now map demo IAS devices to live VPN peers using vpn_peer identifiers.
Current data model is still demo-based; VPN runtime status is live.


Documentation
-------------

* [Runtime modes](docs/RUNTIME-MODES.md) describes the split between static GitHub Pages previews and the live Erlang/N2O runtime.
* [Nitro rendering rules](docs/NITRO-RENDERING.md) documents safe text rendering rules for IAS/Nitro pages.
* [Local CA/CMP test harness](docs/CA-CMP-LOCAL.md) documents the OTP 28 CA runtime and OpenSSL 3 CMP enrollment test.

VPN Integration
---------------

IAS consumes VPN runtime status through the VPN admin HTTP API.

Current integration is read-only.

Future work:
- CA integration
- certificate issuance
- profile-based certificate attributes

Це навчальний приклад освітнього підготовчого курсу для інтернів, який використовується для здодобуття навичок програмування систем на бібліотеках <a href="https://n2o.dev">N2O.DEV</a>.

Структура проекту
-----------------

### Статичні HTML контейнери

* [login.htm](priv/static/login.htm) Сторінка авторизації
* [index.html](priv/static/index.htm) Домашня сторінка
* [forms.html](priv/static/forms.htm) Сторінка всіх форм
* [actors.html](priv/static/actors.htm) Сторінка всіх процесів
* [act.html](priv/static/act.htm) Сторінка історії процесу

### Базові модулі

* [ias_kvs](src/boot/ias_kvs.erl) Схема даних, її налаштування
* [ias_route](src/pages/ias_route.erl) Налаштування маршрутів HTML сторінок для веб-серверу
* [ias](src/ias.erl) Головний модуль Erlang/OTP додатку

### Редактори форм

* [bpe_pass](src/forms/bpe_pass.erl) Форма аутентифікації
* [bpe_create](src/forms/bpe_create.erl) Форма створення процесу
* [bpe_row](src/forms/bpe_row.erl) Таблична форма-рядок відображення процесу
* [bpe_trace](src/forms/bpe_row.erl) Таблична форма-рядок відображення кроку процесу

### Контролери сторінок

* [bpe_act](src/pages/bpe_act.erl) Сторінка відображення історії процесу
* [bpe_forms](src/pages/bpe_forms.erl) Сторінка відображення всіх форм системи
* [bpe_login](src/pages/bpe_login.erl) Сторінка аутентифікації
* [bpe_index](src/pages/bpe_index.erl) Сторінка переліку всіх процесів та їх створення

Автори
-------

* Максим Сохацький

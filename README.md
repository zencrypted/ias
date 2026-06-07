IAS: Identity, Access and Security Administration
================================================

IAS is an Erlang/N2O bootstrap application for Identity, Access and Security Administration.

IAS was forked from FIN and is being renamed as the first IAS application baseline.


Запуск
------

Бізнес-процеси підприємства BPE визначають інфраструктуру для оркестрування виробничих процесів згідно стандарту BPMN, та систем на основі декларативних правил. BPE зберігає транзакційно усі кроки бізнес-процесів у сучасній системі даних KVS на базі RocksDB.

IAS bootstrap currently uses Mnesia-backed KVS.
RocksDB is disabled temporarily for Ubuntu 20.04 compatibility.

```
$ mix deps.get
$ iex -S mix
$ open http://localhost:8041/app/index.html
```

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

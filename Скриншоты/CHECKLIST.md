# Чек-лист скриншотов (все сделаны; проверены глазами на отсутствие ключей и паролей)

Скриншоты — снимки окна терминала WSL2 Ubuntu 24.04 с выводом реально выполненных команд (`scripts/shots/term2png.py`) и снимки CouchDB Fauxton (`scripts/shots/fauxton.py`). Пересъёмка: `scripts/shots/shots_main.sh` (основная сеть), `scripts/shots/shots_bft.sh` (стенд SmartBFT).

## Задание 1 (`task1/`)
- [x] 01 `docker ps` — все контейнеры сети
- [x] 02 `peer version`, `peer channel list`, `getinfo` в окружении Org1
- [x] 03 CLI Org1: Ordering Service + subject/issuer администратора
- [x] 04 `querycommitted` payment (1.0 / 1 / AND)
- [x] 05 approve + checkcommitreadiness (Org2MSP false → true)
- [x] 06 транзакции T1–T5 с `committed with status (VALID)`
- [x] 07 отказы N1 и N2
- [x] 08 MVCC_READ_CONFLICT
- [x] 09 разбор T4 по этапам
- [x] 10 ReadPaymentOrder, пагинация, история PO-0001
- [x] 11 `peer channel getinfo`, последний блок, проверка связности
- [x] 12 статический анализ
- [x] 13 Gateway-клиент
- [x] 14 CouchDB Fauxton — документ PO-0001 (пароль не виден)
- [x] Архитектурная схема — `docs/architecture/01_architecture.png`, `02_tx_flow_pdc.png`, `03_smartbft.png`

## Задание 2 (`task2/`)
- [x] 01 пользователи с атрибутом role
- [x] 02 `querycommitted` paymentvuln и paymentsecure (коллекция)
- [x] 03 успешная атака Org2 на paymentvuln
- [x] 04 история PO-V001, создатель Submit = Org2MSP
- [x] 05 тот же Submit на paymentsecure → ошибка
- [x] 06 SetSettlementDetails с transient (без значений) → VALID
- [x] 07 блок: только хэши, `grep -c` = 0
- [x] 08 CouchDB `$$p`/`$$h` на Org1, только `$$h` на Org2; логи — 0
- [x] 09 SEC-01 (маскировано) и SEC-02/03 (отказ)
- [x] 10 итог security-тестов (17 PASS)
- [x] 11 статический анализ paymentsecure
- [x] 12–13 Fauxton Org1 / Org2

## Задание 3 (`task3/`)
- [x] 01 querycommitted до обновления (1.0 / 1)
- [x] 02 queryinstalled с обоими Package ID
- [x] 03 checkcommitreadiness после одного и двух approve
- [x] 04 отказ при sequence 3, несовпадение политики
- [x] 05 querycommitted после commit (2.0 / 2) и контейнеры 2.0
- [x] 06 чтение PO-0001 (v1.0) через v2.0, sha256 состояния
- [x] 07 Return PO-0001 и история с TxID обеих версий
- [x] 08 таблица C1–C9
- [x] 09 статический анализ v2.0
- [x] 10 бэкап
- [x] 11 `docker ps` с 4 orderer
- [x] 12 конфиг канала: BFT, consenters, V3_0
- [x] 13 `docker stop orderer4` + контрольная транзакция VALID
- [x] 14 восстановление и catch-up
- [x] 15 view change при остановке лидера
- [x] 16 отказ при двух остановленных orderer
- [x] 17 таблица эксперимента
- [x] 18 высоты всех узлов

## Итог
- [x] `final_demo_live.png` — живой прогон `scripts/demo.sh` (37 ✔)

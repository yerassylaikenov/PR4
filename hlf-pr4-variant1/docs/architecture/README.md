# Архитектура сети — ПР №4, Вариант 1 «Банковские операции»

Схема: `architecture_variant1.drawio` (3 листа). PNG: `01_architecture.png` (лист 1), `02_tx_flow_pdc.png` (лист 2), `03_smartbft.png` (лист 3).
Лист 1 сверен с реальной сетью (`docker ps`, `evidence/task1/02_network_up.log`): имена контейнеров, порты, имена CA и CouchDB совпадают; в заголовке уточнена версия — Fabric 3.1.5, Fabric CA 1.5.22.

## Компоненты

| Компонент | Контейнер | Порт (host) | MSP | Роль в варианте 1 |
|---|---|---|---|---|
| Peer Org1 (+ встроенный Fabric Gateway) | `peer0.org1.example.com` | 7051 (operations 9444) | Org1MSP | Банк-отправитель: endorser/committer, Gateway для Sender Bank App |
| Peer Org2 (+ встроенный Fabric Gateway) | `peer0.org2.example.com` | 9051 (operations 9445) | Org2MSP | Банк-получатель: endorser/committer, Gateway для Receiver Bank App |
| Ordering Service (Raft, 1 узел) | `orderer.example.com` | 7050, admin 7053, operations 9443 | OrdererMSP | упорядочивание транзакций, формирование блоков, Channel Participation API |
| Fabric CA Org1 | `ca_org1` (CA name `ca-org1`) | 7054 | Org1MSP | выпуск X.509 для Admin, peer0, initiator1, approver1, norole1 (атрибут `role`) |
| Fabric CA Org2 | `ca_org2` (CA name `ca-org2`) | 8054 | Org2MSP | выпуск X.509 для Admin, peer0, processor2 |
| Fabric CA Orderer | `ca_orderer` | 9054 | OrdererMSP | идентичности orderer и его администратора |
| World State Org1 | `couchdb0` (CouchDB 3.4.2) | 5984 | — | текущие значения ключей peer0.org1, private data `collectionSettlementDetails` |
| World State Org2 | `couchdb1` (CouchDB 3.4.2) | 7984 | — | текущие значения ключей peer0.org2, только хэши private data |
| Chaincode `payment` / `paymentvuln` / `paymentsecure` | `dev-peer0.orgN.example.com-<label>-<hash>` | — | — | бизнес-логика PaymentOrder (отдельные контейнеры, запускаются peer) |
| Client Application | `client/payment-client` (Go, fabric-gateway v1.10.0) | — | Org1MSP / Org2MSP | Sender / Receiver Bank App: Submit/Evaluate через Gateway (gRPC+TLS) |
| Channel | `paymentchannel` | — | Org1MSP, Org2MSP (Application), OrdererMSP (Orderer) | общий ledger двух банков |

Пользователи системы (лист 1): `Admin@org1`, `initiator1` (role=initiator), `approver1` (role=approver), `processor2` (role=processor), `Admin@org2`, `Admin@example.com` (OrdererMSP, osnadmin), внешние клиенты банков (плательщик / получатель) — вне Fabric, без X.509-идентичности.

## Поток транзакции ①–⑥ (Execute → Order → Validate → Commit)

1. Client подписывает proposal (X.509) и отправляет его в Fabric Gateway своей организации (gRPC + TLS).
2. Gateway выполняет симуляцию на peer0.org1 и запрашивает endorsement у peer0.org2 (политика AND): формируются Read/Write Set, ledger не изменяется.
3. Клиент подписывает транзакцию, Gateway отправляет её в Ordering Service.
4. Ordering Service упорядочивает транзакции, формирует блок и доставляет его peers.
5. Каждый peer проверяет Endorsement Policy (VSCC) и версии ключей Read Set (MVCC); write-set валидных транзакций применяется к World State, блок целиком (с кодами валидации) дописывается в Blockchain.
6. Gateway возвращает клиенту статус фиксации: TxID + VALID / MVCC_READ_CONFLICT / ENDORSEMENT_POLICY_FAILURE.

## Доверительные границы (используются в STRIDE, Задание 2)

| ID | Граница | Что пересекает |
|---|---|---|
| TB1 | Граница организации (Org1 / Org2) | свои администраторы, CA, MSP, peers; доверие внутри организации, недоверие к другой |
| TB2 | Client ↔ Peer / Gateway | mTLS + подпись X.509 клиента; proposal, transient data |
| TB3 | Организации ↔ Ordering Service | конверты транзакций, блоки; orderer видит все транзакции канала (хэши private data) |
| TB4 | Peer ↔ контейнер chaincode | shim gRPC; chaincode получает аргументы и transient |
| TB5 | Fabric CA ↔ участники | регистрация и enrollment, атрибуты `role` в ecert |
| TB6 | Внешние клиенты банков ↔ Client Application | вне Fabric: интернет-банк / ДБО, без X.509 |

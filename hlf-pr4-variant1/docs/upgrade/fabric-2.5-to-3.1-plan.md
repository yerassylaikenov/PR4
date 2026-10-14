# План обновления инфраструктуры Hyperledger Fabric 2.5 → 3.1.x

Целевая версия: Fabric **3.1.5**, Fabric CA **1.5.22** (последние patch-релизы по GitHub Releases API на 2026-10-14, `evidence/task1/01_versions.log`).
Последовательность строго: **Backup → Orderers → Peers → Verification → Channel Capabilities**.

Источники (ветка `latest`):
- Upgrading your network components — https://hyperledger-fabric.readthedocs.io/en/latest/upgrade.html
- Considerations for getting to v3.x — https://hyperledger-fabric.readthedocs.io/en/latest/upgrade_to_newest_version.html
- Upgrading your components — https://hyperledger-fabric.readthedocs.io/en/latest/upgrading_your_components.html
- Updating the capability level of a channel — https://hyperledger-fabric.readthedocs.io/en/latest/updating_capabilities.html
- What's new in Fabric v3.x — https://hyperledger-fabric.readthedocs.io/en/latest/whatsnew.html ; release notes v3.0.0 / v3.1.x — https://github.com/hyperledger/fabric/releases

Отличие от документации задания (release-2.5): в ветке `latest` добавлены SmartBFT, capability `V3_0`, удалены Solo/Kafka/legacy lifecycle, рекомендован Fabric Gateway вместо legacy SDK.

## 0. Предусловия (до любых действий)

| # | Проверка | Почему | Как проверить |
|---|---|---|---|
| P1 | **System channel не используется** — все каналы через Channel Participation API | в 3.x system channel удалён | `osnadmin channel list` → `"systemChannel": null` (в нашей сети так и есть, `02_network_up.log`) |
| P2 | **Нет Solo и Kafka** — только Raft (etcdraft) | «Support for 'Solo'/'Kafka' consensus has been removed in Fabric v3.0» | `ConsensusType` в config block = `etcdraft` (`04_cli_env_org1.log`) |
| P3 | **Нет legacy lifecycle** — application capability ≥ `V2_0`, все chaincode переустановлены через `_lifecycle` | «The legacy chaincode lifecycle from v1.x has been removed in Fabric v3.0» | Application capabilities `V2_5`; `peer lifecycle chaincode querycommitted -C <ch>` содержит все chaincode |
| P4 | **OrdererEndpoints на уровне организаций** в каждом канале | обязательно перед `V3_0`: «if one org defines org-level endpoints, all nodes ignore channel-level endpoints» | `jq '.channel_group.groups.Orderer.groups[].values.Endpoints'` |
| P5 | Устаревшие параметры `core.yaml` / `orderer.yaml` | новые бинарники отвергают/игнорируют удалённые ключи (Kafka-, Solo-секции, `General.BootstrapMethod: file` без system channel и т.п.) | `diff` с `fabric-samples/config/*.yaml` 3.1.5 |
| P6 | Совместимость chaincode: Go-shim `fabric-chaincode-go/v2`, `fabric-contract-api-go/v2`, Go-версия ccenv 3.1.5 (go1.26.x) | chaincode пересобирается в новом `fabric-ccenv`; директива `go` в go.mod не выше версии toolchain | `docker run --rm hyperledger/fabric-ccenv:3.1.5 go version`; сборка всех пакетов |
| P7 | Версия CouchDB, поддерживаемая 3.1 (в test-network — 3.4.2) | CouchDB обновляется вместе с peer | `curl http://couchdb:5984/` |
| P8 | Клиентские SDK → **Fabric Gateway** | legacy SDK «are no longer maintained and are not compatible with new v3.0 Fabric features such as SmartBFT» | все приложения используют `fabric-gateway` (наш `client/`) |
| P9 | Окно обслуживания и Go/No-Go согласованы всеми организациями | обновление — совместная процедура консорциума | протокол совещания |

## 1. Backup

| Узел | Что копировать | Порядок |
|---|---|---|
| Orderer | `/var/hyperledger/production/orderer` (ledger + etcdraft WAL/snapshots), MSP и TLS (`/var/hyperledger/orderer/msp`, `tls`), `orderer.yaml`, env/compose | 1) `docker stop` 2) `docker cp`/`tar` 3) `sha256sum` 4) запуск |
| Peer | `/var/hyperledger/production` (ledgersData, chaincodes, transientstore, `pvtdataStore`), MSP/TLS, `core.yaml` | то же; `stateLeveldb`/`historyLeveldb`/`chains/index` можно пропустить ценой долгого восстановления |
| CouchDB | каталог данных `/opt/couchdb/data` | **бэкап CouchDB должен быть старше бэкапа peer** (официальное требование): сначала CouchDB, затем peer |
| Fabric CA | `fabric-ca-server.db` (SQLite/PostgreSQL), `ca-cert.pem`, ключ CA, `fabric-ca-server-config.yaml`, IssuerPublicKey/RevocationKey | остановка CA → копия → контрольные суммы |

Требования: бэкапы с закрытыми ключами шифруются (`age`/`gpg` с ключом из HSM/KMS), хранятся отдельно от узлов, доступ — по принципу двух лиц. **Проверка восстановимости** до начала обновления: восстановить бэкап одного peer на изолированном стенде и сравнить высоту и `currentBlockHash`.

Практическое подтверждение этапа Backup на нашей сети: `scripts/38_backup_volumes.sh` → `evidence/task3/38_backup.log` (tar всех docker volumes + `sha256sum`).

## 2. Orderers — rolling, по одному

Для каждого orderer (наша сеть: один узел Raft; в production — ≥ 3):
```bash
docker stop orderer.example.com
docker cp orderer.example.com:/var/hyperledger/production/orderer ./backup/orderer.example.com   # если не сделано в п.1
docker rm -f orderer.example.com
# тот же volume, env, имя; новый образ
docker run -d --name orderer.example.com ... hyperledger/fabric-orderer:3.1.5 orderer
```
После **каждого** узла, прежде чем переходить к следующему:
- `osnadmin channel list -o <host>:7053 --channelID <ch>` → `status: active`, `consensusRelation: consenter`, высота = высоте остальных;
- в логах: `Raft leader changed` / `Start accepting requests`, нет `panic`/`FATA`;
- кворум Raft (большинство) сохраняется: одновременно недоступен не более одного узла.

Откат на этом этапе: остановить узел, запустить образ 2.5.x с тем же volume (формат ledger совместим, пока не включена `V3_0`) или восстановить volume из бэкапа.

## 3. Peers — по одному на организацию

```bash
docker stop peer0.org1.example.com
docker rm -f $(docker ps -aq --filter name=dev-peer0.org1)              # контейнеры chaincode
docker rmi -f $(docker images -q --filter reference='dev-peer0.org1*')  # образы chaincode (пересоберутся в ccenv 3.1.5)
docker rm -f peer0.org1.example.com
# CouchDB этого peer обновляется одновременно: stop → backup → новый образ → start
docker run -d --name peer0.org1.example.com ... hyperledger/fabric-peer:3.1.5 peer node start
```
- Перезапуск контейнеров chaincode вручную не нужен: peer пересоберёт образ при первом обращении.
- `peer node upgrade-dbs` / `rebuild-dbs`: в руководстве upgrading_your_components для 2.x → 3.x отдельный шаг не указан (формат БД совместим); при неудачном старте — `peer node rebuild-dbs` (пересборка state/history из блоков) с последующей сверкой высоты.
- Обновлять сначала по одному peer в каждой организации, чтобы политика AND оставалась выполнимой (peers разных версий могут endorse, пока chaincode не меняется).

## 4. Verification

| Проверка | Команда | Критерий |
|---|---|---|
| Версии | `peer version`, `orderer version` в контейнерах | 3.1.5 |
| Высоты | `peer channel getinfo -c paymentchannel` на всех peers, `osnadmin channel list` на всех orderer | одинаковые, `currentBlockHash` совпадает |
| Определения chaincode | `peer lifecycle chaincode querycommitted -C paymentchannel` | без изменений (payment 2.0/2, paymentsecure, paymentvuln) |
| Тестовая транзакция | invoke через **Gateway-клиент** (`client/payment-client`) | VALID, блок закоммичен на обоих peers |
| Private data | `ReadSettlementDetails` на peer0.org1 | данные доступны |
| Логи | `docker logs <node> 2>&1 \| grep -E 'ERRO\|PANI\|FATA'` | пусто |
| Сквозная проверка | `scripts/demo.sh` | все ✔ |

## 5. Channel Capabilities → `V3_0` (точка невозврата)

Только после обновления **всех** orderer и peer **всех** организаций канала:
```bash
peer channel fetch config config_block.pb -c paymentchannel -o ... --tls --cafile $ORDERER_CA
configtxlator proto_decode --input config_block.pb --type common.Block | jq .data.data[0].payload.data.config > config.json
jq '.channel_group.values.Capabilities.value.capabilities = {"V3_0": {}}' config.json > modified.json
configtxlator proto_encode --input config.json   --type common.Config --output config.pb
configtxlator proto_encode --input modified.json --type common.Config --output modified.pb
configtxlator compute_update --channel_id paymentchannel --original config.pb --updated modified.pb --output update.pb
# обернуть в Envelope, затем подписи администраторов по политике /Channel/Admins (MAJORITY: Org1 + Org2 + OrdererOrg)
peer channel signconfigtx -f update_envelope.pb          # Admin@org1, Admin@org2, Admin@orderer
peer channel update -f update_envelope.pb -c paymentchannel -o ... --tls --cafile $ORDERER_CA
```
Проверка: повторный `fetch config` → `channel_group.values.Capabilities` = `V3_0`; тестовая транзакция VALID.
Предварительно (P4) — `OrdererEndpoints` перенесены на уровень организаций отдельным config update.

**После `V3_0` откат бинарников на 2.5 невозможен**: узлы 2.5 не понимают capability `V3_0` и остановятся на этом блоке конфигурации. Откат возможен только восстановлением из бэкапа (с потерей транзакций после точки бэкапа).

## Плана отката по этапам

| Этап | Откат |
|---|---|
| 0–1 | ничего не изменено |
| 2 (orderers) | вернуть образ 2.5.x на тот же volume / восстановить volume; кворум сохраняется, т.к. узлы обновляются по одному |
| 3 (peers) | вернуть образ 2.5.x, удалить образы chaincode (пересоберутся в ccenv 2.5), CouchDB — из бэкапа (старше бэкапа peer) |
| 4 | при провале проверок — откат этапов 3, 2 |
| 5 | **точка невозврата**; только полное восстановление из бэкапа на всех узлах |

## Матрица рисков

| Риск | Вероятность | Влияние | Мера |
|---|---|---|---|
| Потеря кворума Raft при одновременном обновлении нескольких orderer | средняя | высокое (остановка упорядочивания) | строго по одному узлу, проверка лидера/высот перед следующим |
| Chaincode не собирается в новом ccenv (Go-версия, зависимости) | средняя | высокое (endorsement недоступен) | P6: предварительная сборка всех пакетов в `fabric-ccenv:3.1.5`; vendor |
| Несовместимые параметры `core.yaml`/`orderer.yaml` | средняя | среднее | P5: diff конфигов, тест на стенде |
| Рассинхронизация CouchDB и ledger peer | низкая | высокое | бэкап CouchDB старше peer; `rebuild-dbs` при сомнениях |
| Legacy-SDK клиенты перестают работать с новыми функциями | средняя | среднее | P8: Fabric Gateway |
| Включение `V3_0` до обновления всех узлов | низкая | критическое (узлы 2.5 останавливаются) | чек-лист версий всех узлов перед config update, подписи всех Admins |
| Утечка бэкапов с ключами MSP | низкая | критическое | шифрование, отдельное хранилище, доступ двух лиц |

## Окно обслуживания и Go/No-Go

- Окно: нерабочее время банков (низкий поток платежей), длительность ≈ 2 ч на канал; уведомление участников за 5 рабочих дней.
- **Go**, если: P1–P9 выполнены; бэкапы сделаны и восстановление проверено; стенд-репетиция прошла; все организации подтвердили готовность.
- **No-Go / остановка**: любой узел не вернулся в синхронизацию за 15 мин; тестовая транзакция не VALID; расхождение `currentBlockHash`; ошибки сборки chaincode.

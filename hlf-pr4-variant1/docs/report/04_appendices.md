## Приложение А. Структура репозитория и воспроизведение

```
hlf-pr4-variant1/
├── CLAUDE.md, README.md, .gitignore
├── chaincode/payment-v1 | payment-vuln | payment-secure | payment-v2   # Go chaincode + unit-тесты
├── client/                      # Go-клиент Fabric Gateway (payment-client)
├── collections/collections_config.json
├── scripts/                     # все шаги: 00…40, lifecycle.sh, analyze_tx.sh, demo.sh, demo_bft.sh, lib.sh, redact.sh
├── tests/security/run_security_tests.sh
├── evidence/task1|task2|task3|final/   # логи после redaction, txids.csv, таблицы
└── docs/architecture | chaincode | security | upgrade | report
```

Воспроизведение с нуля (WSL2 Ubuntu, Docker, Go): `scripts/00_check_env.sh` → `01_install_fabric.sh` → `02_network_up.sh` → `04_cli_env_org1.sh` → `07_static_analysis.sh` → `lifecycle.sh -n payment -p chaincode/payment-v1 -v 1.0 -s 1` → `10_transactions.sh` → `10b_mvcc_demo.sh` → `analyze_tx.sh <T4>` → `12_state.sh` → `13_ledger_info.sh` → `20_register_users.sh` → `lifecycle.sh` для `paymentvuln` и `paymentsecure` (`-c collections/collections_config.json`) → `21_exploit_vuln.sh` → `23_private_data_flow.sh` → `25_exploit_secure.sh` → `tests/security/run_security_tests.sh` → `30_pre_upgrade_snapshot.sh` → `lifecycle.sh … -v 2.0 -s 2 --stop-before-commit` → `34_negative_lifecycle.sh` → `35_commit_v2.sh` → `36_compat_check.sh` → `38_backup_volumes.sh` → `39_bft_up.sh` → `39_bft_config.sh` → `lifecycle.sh … -C bftchannel` → `39_bft_experiment.sh` → `40_restore_main.sh`. Демонстрация на защите: `scripts/demo.sh` (≈ 2–3 мин, 37 проверок), `scripts/demo.sh --full`, `scripts/demo_bft.sh`.

## Приложение Б. Индекс доказательств

| Раздел отчёта | Файл в `evidence/` | Скриншот |
|---|---|---|
| 1 Среда, версии | `task1/00_check_env.log`, `task1/01_versions.log` | — |
| 2.1 Сеть | `task1/02_network_up.log` | рис. 1 |
| 2.3 CLI Org1 | `task1/04_cli_env_org1.log` | рис. 4, 5 |
| 3.1 Тесты и анализ v1.0 | `task1/07_static_analysis.log`, `task1/attempt1/` | рис. 6 |
| 3.2 Деплой 1.0/1 | `task1/08_lifecycle_payment_1.0.log` | рис. 7, 8 |
| 3.3 Транзакции, MVCC | `task1/10_transactions.log`, `task1/10b_mvcc_demo.log`, `task1/txids.csv` | рис. 9–12 |
| 3.4 Разбор T4 | `task1/11_analyze_tx_6d535b17ed87.log`, `task1/tx_anatomy_6d535b17….md` | рис. 13 |
| 3.5 Состояние | `task1/12_state.log`, `task1/state_table.md` | рис. 14, 15 |
| 3.6 Ledger | `task1/13_ledger_info.log`, `task1/13_newest_block_decoded_fragment.json` | рис. 16 |
| 4.3 Пользователи | `task2/20_register_users.log`, `task2/20b_rotate_secrets.log` | рис. 17 |
| 4.4 Уязвимость | `task2/22_vuln_diff.patch`, `task2/22_lifecycle_paymentvuln.log`, `task2/21_exploit.log`, `task2/txids.csv` | рис. 18, 19 |
| 4.5 Защита | `task2/27_static_analysis_paymentsecure.log`, `task2/25_exploit_secure.log` | рис. 20 |
| 5.1 PDC, деплой | `task2/24_lifecycle_paymentsecure.log` | рис. 21 |
| 5.2 Transient | `task2/23_private_flow.log`, `task2/23_setsettlement_block_decoded.json` | рис. 22–26 |
| 5.3 Security-тесты | `task2/security_tests.log`, `task2/security_tests.md` | рис. 27, 28 |
| sequence `payment` не менялся | `task2/00_precheck.log`, `task2/99_postcheck.log` | — |
| 6.1 Снимок | `task3/30_pre_upgrade_snapshot.log`, `task3/30_pre_upgrade/` | рис. 29 |
| 6.2 v2.0 | `task3/32_static_analysis_payment_v2.log` | — |
| 6.3 Lifecycle 2.0/2 | `task3/33_install_payment_2.0.log`, `task3/34_approve_payment_2.0.log`, `task3/34_negative_lifecycle.log`, `task3/35_commit.log` | рис. 30–33 |
| 6.4 Совместимость | `task3/36_compat.log`, `task3/compat_table.md`, `task3/state_after.json`, `task3/txids.csv` | рис. 34–36 |
| 6.5 Backup / restore | `task3/38_backup.log`, `task3/40_restore_main.log` | рис. 37 |
| 7 SmartBFT | `task3/bft/39_bft_up.log`, `39_bft_config.log`, `39_bft_lifecycle_payment.log`, `39_bft_experiment.log`, `experiment.md`, `*_run1.*` | рис. 38–46 |
| Итоговые проверки | `final/scan_secrets.log`, `final/verify_report_facts.log`, `final/completeness.md` | — |

## Приложение В. Ответы на контрольные вопросы

### 1. Жизненный цикл транзакции Execute → Order → Validate → Commit; где транзакция может стать недействительной; роль MVCC

**Execute.** Клиент формирует proposal (канал, chaincode, функция, аргументы, при необходимости transient), подписывает его своим X.509 и отправляет в Fabric Gateway. TxID вычисляется как SHA-256(nonce ‖ creator) — в разборе T4 он пересчитан и совпал. Gateway отправляет proposal endorsing-peers, достаточным для Endorsement Policy (у нас AND — peer0.org1 и peer0.org2). Peer проверяет подпись и права клиента, запускает chaincode в симуляции: ledger не меняется, формируется RW-set — Read Set (ключи с версиями «блок/транзакция», у T4 — `PO-0001` версии 8/0) и Write Set. Peer подписывает ответ (endorsement). На этом этапе транзакция может быть **отклонена ещё до ledger**: ошибка chaincode (N1 — `ERR_INVALID_TRANSITION`, N2 — `ERR_UNAUTHORIZED`), отказ в доступе, несовпадение ответов endorsers, невозможность собрать политику. Такие транзакции вообще не попадают в блоки — у N1/N2 нет TxID в ledger.

**Order.** Клиент подписывает транзакцию с endorsements, Gateway отправляет её в Ordering Service. Orderer **не исполняет** chaincode и не проверяет бизнес-логику; он проверяет право отправителя писать в канал (политика Writers), формат и размер, упорядочивает транзакции, формирует блок (BatchSize/BatchTimeout), подписывает его и доставляет peers. Эксперимент показал: копия блока у orderer не содержит `TRANSACTIONS_FILTER` — валидация ещё не выполнена.

**Validate.** Каждый peer независимо проверяет каждую транзакцию блока: подписи, VSCC — удовлетворяет ли набор endorsements политике (иначе `ENDORSEMENT_POLICY_FAILURE`), дубликат TxID (`DUPLICATE_TXID`), и **MVCC**: совпадает ли версия каждого ключа из Read Set с текущей версией в World State. Если ключ изменила более ранняя транзакция того же или предыдущего блока — `MVCC_READ_CONFLICT`; для range-запросов — `PHANTOM_READ_CONFLICT`.

**Commit.** Блок **целиком**, включая невалидные транзакции с кодами в `TRANSACTIONS_FILTER`, дописывается в Blockchain; к World State применяются write-set только валидных транзакций; обновляется History DB; клиент получает статус через Gateway.

**Роль MVCC.** Это оптимистичная конкурентность без блокировок: симуляция идёт параллельно, а конфликт обнаруживается при валидации. Она защищает от lost update и двойного исполнения. Наш пример: M1 (Submit) и M2 (Cancel) PO-0005 были endorse-ены по одной версии ключа, упорядочены в блок 14; M2 применена (VALID), M1 получила `MVCC_READ_CONFLICT` — она лежит в блоке, но PO-0005 остался CANCELLED с `lastTxId` M2. Без MVCC обе транзакции «перезаписали» бы друг друга, и итог зависел бы от порядка применения.

### 2. Endorsement Policy vs авторизация в chaincode; может ли транзакция удовлетворять EP и нарушать бизнес-логику

Endorsement Policy — правило уровня канала, определяющее, **чьи peers** должны подтвердить результат исполнения chaincode, чтобы транзакция считалась валидной. Она проверяется на этапе Validate (VSCC) и отвечает на вопрос «согласны ли нужные организации, что этот код при этом состоянии даёт этот RW-set». EP ничего не знает о вызывающем пользователе, его роли и о бизнес-правилах: она защищает от того, что одна организация подделает результат исполнения, но не от того, что сам код разрешает недопустимое действие.

Авторизация вызывающего — ответственность chaincode: проверка MSP (`GetMSPID`), атрибутов (`AssertAttributeValue("role", …)`), идентичности (`GetID` — например, принцип четырёх глаз), текущего состояния объекта и допустимости перехода.

**Да, транзакция может удовлетворять EP и нарушать бизнес-логику** — это доказано практически. В `paymentvuln` функция Submit не проверяла MSP. Сотрудник банка-получателя `processor2` (Org2MSP) выполнил Submit чужого поручения PO-V001: транзакция `e4545b3d…4fe5` в блоке 22 имеет создателя Org2MSP, endorsements **Org1MSP и Org2MSP** и код **VALID**. Затем Org2 сама выполнила Accept и Settle — платёж исполнен без авторизации банка-отправителя. Политика AND была выполнена честно: оба peers исполнили один и тот же ошибочный код, получили одинаковый RW-set и подписали его. Нарушены инварианты INV-4 (авторизует списание только approver банка-отправителя) и INV-SoD (ни одна организация не проводит платёж единолично) — это OWASP SC01 (Access Control) с последствием SC03 (Logic Errors).

В `paymentsecure` тот же вызов отклонён на этапе endorsement: `ERR_UNAUTHORIZED: caller organisation is not allowed to perform this operation` (SEC-04, `25_exploit_secure.log`). Дополнительный механизм Fabric — **state-based endorsement** (`SetStateValidationParameter`): для конкретного ключа можно задать собственную политику, например требовать подписи только организации-владельца. Но и он определяет подписантов результата, а не права вызывающего, поэтому проверки в chaincode остаются обязательными.

### 3. Channel vs Private Data Collection

**Изоляция участников.** Channel — отдельная «подсеть» со своим членством и конфигурацией: организации вне канала не знают ни о транзакциях, ни даже о факте отношений участников. PDC существует **внутри** канала: все участники канала видят, что транзакция была, и видят хэши private data; открытые значения получают только члены коллекции (у нас — `OR('Org1MSP.member')`).

**Хранение и ledger.** У канала свой Blockchain и World State на каждом peer-участнике. Private data хранятся в отдельной БД только у peers-членов (`$$p`-база в CouchDB peer0.org1 и pvtdata store); в блоках канала и у остальных peers — только хэши ключа и значения (`collection_hashed_rwset`, `$$h`-база на peer0.org2). Orderer видит все транзакции канала целиком, но для private data — только хэши. Передача: через transient в proposal и gossip между членами (`requiredPeerCount`, `maxPeerCount`); срок жизни — `blockToLive`, удаление — `PurgePrivateData`.

**Политики доступа.** Канал: политики Readers/Writers/Admins, LifecycleEndorsement, Endorsement Policy chaincode. PDC: `policy` членства, `memberOnlyRead/Write` (peer сам отклоняет чужих клиентов), collection-level endorsement policy (`OR('Org1MSP.peer')` позволила записывать реквизиты подписью одного peer0.org1).

**Когда что.** Канал — если нужно скрыть сам факт взаимодействия, разные наборы участников и правил, изолировать нагрузку и данные полностью (ценой административных издержек на каждый канал). PDC — если участники общие и процесс общий, а конфиденциальна часть данных. Наш случай: оба банка ведут общее поручение, а реквизиты нужны только банку-отправителю; банк-получатель лишь сверяет их хэш с солью (`VerifySettlementDetails`, SEC-13).

**Нюансы.** (1) Transient уходит ко всем endorsers, указанным клиентом/Gateway: если реквизиты передать в транзакции с AND-политикой, их получит peer Org2 — поэтому запись реквизитов вынесена в отдельную транзакцию, endorse-имую только Org1, а chaincode отказывает на peer не из Org1 (SEC-17). (2) Хэш низкоэнтропийных данных (12-значный БИН, проверяемый IBAN) перебирается — нужна соль от клиента. (3) Private data не должны попадать в логи и тексты ошибок (SEC-15: 0 совпадений).

### 4. version, sequence, package ID; зачем увеличивать sequence; сохранность World State

**version** — метка определения chaincode, задаваемая администраторами («1.0», «2.0»). Сама по себе ничего не запускает и не обязана расти; это информационное поле, помогающее людям.

**sequence** — счётчик изменений определения chaincode в канале. Любое изменение определения (пакет, политика, коллекции, `init-required`, плагины) требует нового определения с sequence ровно на 1 больше текущего; все организации утверждают одно и то же значение. Это защищает от рассинхронизации (организации не могут утвердить «разные» обновления), от повторного применения старых определений и делает порядок изменений однозначным. Наша демонстрация: approve с `--sequence 3` при зафиксированной 1 отклонён — `requested sequence 3 is larger than the next available sequence number 2`. Определение «совпадает» только при идентичных параметрах: `checkcommitreadiness` с политикой OR или без `--signature-policy` показал `false/false`, хотя обе организации уже утвердили версию с AND, — поэтому политику передают явно и одинаково, иначе модель доверия молча сменится на политику канала по умолчанию.

**package ID** = label + SHA-256 пакета (`payment_2.0:14d12cad…`). Он связывает утверждение конкретной организации с кодом, установленным на её peers: каждая организация в `approveformyorg` указывает, какой установленный пакет исполнять для этого определения. Установка пакета ничего не меняет в канале (на peers одновременно стояли 1.0 и 2.0), код начинает исполняться только после commit. Упаковка детерминирована: повторная упаковка тех же исходников дала тот же Package ID.

**Сохранность World State.** Состояние принадлежит **namespace chaincode** (имени `payment` в канале), а не пакету. Commit sequence 2 переключил исполняемый код, но ключи остались на месте: `GetAllPaymentOrders` через v2.0 дал файл с тем же sha256 `69f0ea3b…`, что и снимок v1. Совместимость обеспечивает разработчик: ключи и JSON-поля не меняются, новые поля опциональны, ленивая миграция (`schemaVersion` появляется при первой записи — C3), старые функции сохраняют сигнатуры — все 70 тестов v1.0 прошли на v2.0 без изменений, а история PO-0001 содержит TxID обеих версий (C8).

### 5. Raft CFT vs SmartBFT BFT; почему остановка одного orderer не доказывает устойчивость к Byzantine behavior

**Raft** — протокол консенсуса с аварийной отказоустойчивостью (CFT): n = 2f + 1, выдерживает отказ меньшинства узлов (остановка, потеря связи). Есть лидер, который упорядочивает транзакции и реплицирует журнал; узлы предполагаются честными. Злонамеренный лидер может цензурировать или переупорядочивать транзакции, блок подписывает один узел. В нашей основной сети один Raft-orderer: f = 0, его остановка полностью останавливает упорядочивание.

**SmartBFT** — византийская отказоустойчивость (BFT): n = 3f + 1, кворум ⌈(n + f + 1)/2⌉. У нас n = 4, f = 1, кворум 3. Сообщения протокола подписаны, follower-ы проверяют предложения лидера, блок подписывает кворум (в блоке 15 — 3 подписи), а при подозрении на лидера (запрос не упорядочен в срок — `OnRequestTimeout`, `OnLeaderFwdRequestTimeout`) выполняется view change. Цена — больше узлов (4 вместо 3 для f = 1), больше сообщений, задержки при смене лидера.

**Наши результаты.** Остановка не-лидера orderer4 — контрольная транзакция VALID, высота H+1 на трёх живых orderer и обоих peers; после `docker start` orderer4 догнал канал при следующем раунде консенсуса. Остановка лидера — view change (view 3, лидер 4) и VALID через ≈ 56 с. Остановка двух узлов (2 < 3) — блок не формируется; после восстановления кворума транзакция из request pool упорядочена.

**Почему это не доказательство BFT.** `docker stop` моделирует crash fault: узел **молчит**. Византийский узел действует активно и злонамеренно: рассылает разным узлам противоречивые предложения (equivocation), подписывает конфликтующие блоки, будучи лидером, предлагает некорректные блоки или цензурирует транзакции отдельной организации, выборочно задерживает сообщения, участвует в view change с ложными данными. Протокол рассчитан на такие узлы, но наш эксперимент ни одной такой ситуации не создаёт, поэтому подтверждает только устойчивость к остановке узла и смене лидера. Для проверки BFT нужны модифицированный orderer с внедрением ошибок, сетевые разбиения и задержки между конкретными узлами (`tc netem`, `iptables`), сценарии с недобросовестным лидером, а для гарантий — формальная верификация протокола (TLA+, модель-чекинг) и аудит реализации.

### Вероятные дополнительные вопросы на защите

1. **Почему соль генерирует клиент, а не chaincode?** Chaincode исполняется на нескольких endorsers; `crypto/rand` дал бы каждому peer свою соль → разные RW-set → endorsement не соберётся (SC09). Клиент генерирует соль один раз и передаёт её в transient.
2. **Что увидит orderer в транзакции с private data?** Только хэши ключа и значения в `collection_hashed_rwset`, аргументы функции (у нас только ID) и endorsements; transient в блок не попадает (`TransientMap` в блоке пуст).
3. **Что будет, если Org2 утвердит другой Package ID?** Определение (version, sequence, политика, коллекции) может совпасть, и commit пройдёт; но peer Org2 будет исполнять свой пакет. Если код отличается по результату, RW-set endorsers не совпадут и транзакции не соберут AND-политику; если совпадает — всё работает. Package ID — локальное решение организации, не часть определения канала.
4. **Почему GetState не видит PutState той же транзакции?** Во время симуляции записи копятся в Write Set и применяются только при commit; чтения идут из закоммиченного состояния. Поэтому проверки делаются до записи, а «прочитать своё» нельзя (аналог SC05).
5. **Чем memberOnlyWrite отличается от collection-level EP?** `memberOnlyWrite` — проверка на этапе Execute: писать в коллекцию могут только клиенты организаций-членов. Collection-level EP — проверка на этапе Validate: какие peers должны подписать транзакцию, пишущую в коллекцию.
6. **Почему для денег нельзя использовать float?** Двоичное представление не точно (0.1 + 0.2 ≠ 0.3), ошибки накапливаются, а сериализация float в JSON может отличаться — недетерминизм между endorsers. Деньги храним в целых минимальных единицах (тиын, `int64`) с проверкой диапазона.
7. **Почему TxID нельзя выбрать произвольно?** TxID = SHA-256(nonce ‖ creator); peer проверяет это при endorsement, а повтор отклоняется как `DUPLICATE_TXID` — защита от replay на уровне протокола.
8. **Что произойдёт, если версия ключа изменится между симуляцией и валидацией?** `MVCC_READ_CONFLICT` — транзакция остаётся в блоке, но не меняет World State (M1 в блоке 14).
9. **Зачем Gateway-клиент, если есть peer CLI?** Gateway сам выбирает endorsers по политике, собирает endorsements, отправляет в orderer и ждёт статус; это рекомендуемый API для Fabric 3.x (legacy SDK не поддерживают SmartBFT). `WithEndorsingOrganizations("Org1MSP")` позволил отправить private-only транзакцию только Org1 (S4).
10. **Почему валидационные коды есть только в блоке на peer?** Orderer не валидирует транзакции; `TRANSACTIONS_FILTER` заполняет peer при commit. Мы это наблюдали: у копии блока от orderer поле пустое, у копии из ledger peer — заполнено.

## Приложение Г. Источники

1. Hyperledger Fabric documentation (latest) — Using the Fabric test network: https://hyperledger-fabric.readthedocs.io/en/latest/test_network.html
2. Fabric chaincode lifecycle: https://hyperledger-fabric.readthedocs.io/en/latest/chaincode_lifecycle.html
3. Using Private Data in Fabric: https://hyperledger-fabric.readthedocs.io/en/latest/private_data_tutorial.html ; Private data: https://hyperledger-fabric.readthedocs.io/en/latest/private-data/private-data.html
4. Upgrading your network components: https://hyperledger-fabric.readthedocs.io/en/latest/upgrade.html ; Considerations for getting to v3.x: https://hyperledger-fabric.readthedocs.io/en/latest/upgrade_to_newest_version.html ; Upgrading your components: https://hyperledger-fabric.readthedocs.io/en/latest/upgrading_your_components.html ; Updating the capability level of a channel: https://hyperledger-fabric.readthedocs.io/en/latest/updating_capabilities.html
5. What's new in Hyperledger Fabric v3.x: https://hyperledger-fabric.readthedocs.io/en/latest/whatsnew.html ; Release notes: https://github.com/hyperledger/fabric/releases
6. Документация задания (release-2.5): https://hyperledger-fabric.readthedocs.io/en/release-2.5
7. Fabric Gateway client API: https://hyperledger.github.io/fabric-gateway/ ; fabric-contract-api-go: https://github.com/hyperledger/fabric-contract-api-go
8. OWASP Smart Contract Top 10 (2025): https://owasp.org/www-project-smart-contract-top-10/
9. ISO 13616 (IBAN), ISO 9362 (BIC), ISO 4217 (коды валют).

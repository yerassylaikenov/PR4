# Полнота по заданию (пункт → раздел → доказательство → статус)


| Пункт | Требование | Раздел | Доказательство | Статус |
|---|---|---|---|---|
| 1.1 | Сеть: 2 организации, peers, Ordering Service, Fabric CA, отдельный канал | 2.1 | `evidence/task1/02_network_up.log` | ✅ |
| 1.2 | CLI и административная идентичность Org1 (Peer + Orderer) | 2.3 | `task1/04_cli_env_org1.log` | ✅ |
| 1.3 | Архитектурная схема; chaincode ≥ 6 операций, валидация, переходы | 2.2, 3.1 | `docs/architecture/`, `task1/07_static_analysis.log` | ✅ |
| 1.4 | Деплой 1.0 / 1, политика обеих организаций, querycommitted | 3.2 | `task1/08_lifecycle_payment_1.0.log` | ✅ |
| 1.5 | ≥ 4 транзакции с TxID; разбор одной по этапам | 3.3, 3.4 | `task1/txids.csv` (9 VALID), `tx_anatomy_6d535b17….md` | ✅ |
| 1.6 | Состояние бизнес-объектов | 3.5 | `task1/12_state.log` | ✅ |
| 1.7 | Ledger: высота, последний блок, Blockchain vs World State | 3.6 | `task1/13_ledger_info.log` | ✅ |
| 2.1 | Модель угроз, STRIDE ≥ 6 угроз по 7 компонентам | 4.1 | `docs/security/threat-model.md` (15 угроз) | ✅ |
| 2.2 | Уязвимая версия с одной ошибкой под отдельным именем | 4.4 | `paymentvuln`, `task2/22_vuln_diff.patch` | ✅ |
| 2.3 | Воспроизведение от Org2, нарушенный инвариант | 4.4 | `task2/21_exploit.log` | ✅ |
| 2.4 | Защищённая версия: MSP, идентичность, роли, переходы, инварианты, GetTransient/PutPrivateData/GetPrivateData | 4.5 | `chaincode/payment-secure`, `task2/25_exploit_secure.log` | ✅ |
| 2.5 | PDC только для разрешённой организации, отдельное имя | 5.1 | `task2/24_lifecycle_paymentsecure.log` | ✅ |
| 2.6 | Transient; реквизитов нет в аргументах и публичном ledger | 5.2 | `task2/23_private_flow.log` | ✅ |
| 2.7 | ≥ 6 security-тестов; Org1 читает, Org2 — отказ | 5.3 | `task2/security_tests.md` (17 PASS) | ✅ |
| 3.1 | Исходное состояние 1.0 / 1, Package ID, объекты | 6.1 | `task3/30_pre_upgrade/` | ✅ |
| 3.2 | Chaincode 2.0, совместимость, Package ID | 6.2 | `chaincode/payment-v2`, `task3/33_install_payment_2.0.log` | ✅ |
| 3.3–3.5 | Install, approve 2.0 / 2 с той же политикой, commit | 6.3 | `task3/34_*.log`, `task3/35_commit.log` | ✅ |
| 3.6 | Совместимость (объект v1, старая и новая операции); план 2.5 → 3.1.x | 6.4, 6.5 | `task3/compat_table.md`, `docs/upgrade/fabric-2.5-to-3.1-plan.md` | ✅ |
| 3.7 | Стенд SmartBFT, отказ одного orderer, контрольная транзакция, восстановление | 7 | `task3/bft/experiment.md` | ✅ |

**Пороги оценки.** Сеть и chaincode работают (порог 50) — разделы 2–3; есть практическое доказательство разграничения доступа и исправления уязвимой бизнес-логики (порог 70) — разделы 4.4–5.3; выполнено обновление sequence 1 → 2 с доказательством сохранения старого состояния (порог 80) — раздел 6. Закрытые ключи, пароли и сертификаты с ключами в отчёт и репозиторий не включены (`evidence/final/scan_secrets.log`).

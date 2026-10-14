# ПР №4 · Hyperledger Fabric 3.1.5 · Вариант 1 «Банковские операции»

Айкенов Е.Ә., SSE-2502, Astana IT University. Org1 — Банк-отправитель, Org2 — Банк-получатель, бизнес-объект `PaymentOrder`, конфиденциальные данные — расчётные реквизиты.

**Отчёт:** [`docs/report/REPORT.md`](docs/report/REPORT.md) (и `REPORT.docx`). **Доказательства:** [`evidence/`](evidence/). **Схема:** [`docs/architecture/`](docs/architecture/).

## Демонстрация на защите

```bash
cd ~/hlf-pr4-variant1
./scripts/demo.sh             # ≈ 2–3 мин: живые проверки всех трёх заданий, 37 ✔ (Enter — следующий раздел)
./scripts/demo.sh --full      # + все 17 security-тестов
./tests/security/run_security_tests.sh   # только security-тесты
./scripts/demo_bft.sh         # ≈ 10–15 мин: бэкап → стенд SmartBFT → эксперимент → восстановление основной сети
```

Если после перезагрузки ноутбука сеть остановлена: запустить Docker Desktop, затем
`docker start ca_org1 ca_org2 ca_orderer couchdb0 couchdb1 orderer.example.com peer0.org1.example.com peer0.org2.example.com`
(тома сохраняются; контейнеры chaincode поднимутся при первом обращении).

## Состав

| Каталог | Содержимое |
|---|---|
| `chaincode/payment-v1` | `payment` 1.0 — state machine, валидация, 70 unit-тестов, покрытие 97 % |
| `chaincode/payment-vuln` | учебная уязвимая версия (Submit без проверки MSP) |
| `chaincode/payment-secure` | MSP + роль + четыре глаза + PDC `collectionSettlementDetails` |
| `chaincode/payment-v2` | `payment` 2.0 — Return, SetValueDate, rich query; совместимость с World State 1.0 |
| `client/` | Go-клиент Fabric Gateway |
| `scripts/` | все шаги (00…40), `lifecycle.sh`, `analyze_tx.sh`, `demo.sh`, `redact.sh`, проверки |
| `tests/security/` | 17 security-тестов против живой сети |
| `evidence/` | логи после redaction, TxID, таблицы, итоговые проверки (`final/`) |
| `docs/` | архитектура, спецификация, безопасность (STRIDE, OWASP SC Top 10 2025), обновление, отчёт и скриншоты |

## Воспроизведение с нуля

Порядок скриптов — Приложение А отчёта. Требования: WSL2 Ubuntu 24.04, Docker (Desktop) + Compose v2, Go ≥ 1.25, jq, curl, xxd, python3, pandoc (для docx).
Правила работы с репозиторием — [`CLAUDE.md`](CLAUDE.md). Секреты (`.secrets/`, `backup/`, `organizations/`, `fabric-samples/`) в git не попадают.

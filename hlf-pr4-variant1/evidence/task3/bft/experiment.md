# Эксперимент SmartBFT — bftchannel (n = 4, f = 1, кворум 3)

Скрипт `scripts/39_bft_experiment.sh`, 2026-10-14 12:40:29. Высоты: `osnadmin channel list` на admin-порту каждого orderer и `peer channel getinfo` на каждом peer; «—» — узел остановлен.

| Шаг | Действие | Живые orderer | Кворум | Результат | TxID | Высоты |
|---|---|---|---|---|---|---|
| E1 | базовая транзакция | 4/4 | да (4 ≥ 3) | VALID | `c352d1322282a166…` | orderer=12 orderer2=12 orderer3=12 orderer4=12 peer0.org1=12 peer0.org2=12 |
| E2 | docker stop orderer4 (не лидер), 12:36:21 | 3/4 | да (3 ≥ 3) | — | - | orderer=12 orderer2=12 orderer3=12 orderer4=— peer0.org1=12 peer0.org2=12 |
| E3 | контрольная транзакция при отказе 1 узла | 3/4 | да | VALID | `421a1005524b5157…` | orderer=13 orderer2=13 orderer3=13 orderer4=— peer0.org1=13 peer0.org2=13 |
| E4 | docker start orderer4, catch-up, транзакция | 4/4 | да | VALID | `833f7a4171ed7148…` | orderer=14 orderer2=14 orderer3=14 orderer4=14 peer0.org1=14 peer0.org2=14 |
| E5 | docker stop лидера (orderer3) → view change, транзакция через orderer2 | 3/4 | да | VALID (55.5 c) | `d4c4aecb675bc38a…` | orderer=15 orderer2=15 orderer3=— orderer4=15 peer0.org1=15 peer0.org2=15 |
| E6 | docker start orderer3, catch-up | 4/4 | да | — | - | orderer=15 orderer2=15 orderer3=15 orderer4=15 peer0.org1=15 peer0.org2=15 |
| E7 | docker stop orderer3 + orderer (2 > f), транзакция через orderer4 | 2/4 | **нет** (2 < 3) | TIMEOUT_NO_BLOCK (ожидание 40.1 c) | `51db99eca1ca07ee…` (упорядочена после восстановления кворума, блок 15) | orderer=— orderer2=15 orderer3=— orderer4=15 peer0.org1=15 peer0.org2=15 |
| E8 | docker start orderer3 + orderer, транзакция | 4/4 | да | VALID (63.2 c) | `6093a49fb32b1884…` | orderer=16 orderer2=16 orderer3=16 orderer4=16 peer0.org1=16 peer0.org2=16 |

Транзакция E7 после восстановления кворума: `PaymentOrderExists(PO-BFT-E7-123841) = true`, упорядочена в блок 15 (VALID), TxID `51db99eca1ca07ee29035c7713ced4ee579660477f45b4ed8c29c3d0d517646e`.
Блок #15 подписан 3 orderer-ами (metadata SIGNATURES).

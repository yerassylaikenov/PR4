# Эксперимент SmartBFT — bftchannel (n = 4, f = 1, кворум 3)

Скрипт `scripts/39_bft_experiment.sh`, 2026-10-14 12:34:31. Высоты: `osnadmin channel list` на admin-порту каждого orderer и `peer channel getinfo` на каждом peer; «—» — узел остановлен.

| Шаг | Действие | Живые orderer | Кворум | Результат | TxID | Высоты |
|---|---|---|---|---|---|---|
| E1 | базовая транзакция | 4/4 | да (4 ≥ 3) | VALID | `12a21f5a863fe754…` | orderer=7 orderer2=7 orderer3=7 orderer4=7 peer0.org1=7 peer0.org2=7 |
| E2 | docker stop orderer4 (не лидер), 12:29:28 | 3/4 | да (3 ≥ 3) | — | - | orderer=7 orderer2=7 orderer3=7 orderer4=— peer0.org1=7 peer0.org2=7 |
| E3 | контрольная транзакция при отказе 1 узла | 3/4 | да | VALID | `03434274bea22f8b…` | orderer=8 orderer2=8 orderer3=8 orderer4=— peer0.org1=8 peer0.org2=8 |
| E4 | docker start orderer4, catch-up, транзакция | 4/4 | да | VALID | `5a8c790d855cc1f4…` | orderer=9 orderer2=9 orderer3=9 orderer4=9 peer0.org1=9 peer0.org2=9 |
| E5 | docker stop лидера (orderer) → view change, транзакция через orderer2 | 3/4 | да | VALID (52.9 c) | `6f43e299fddec654…` | orderer=— orderer2=10 orderer3=10 orderer4=10 peer0.org1=10 peer0.org2=10 |
| E6 | docker start orderer, catch-up | 4/4 | да | — | - | orderer=10 orderer2=10 orderer3=10 orderer4=10 peer0.org1=10 peer0.org2=10 |
| E7 | docker stop orderer4 + orderer3 (2 > f), транзакция через orderer2 | 2/4 | **нет** (2 < 3) | REJECTED_AT_ENDORSEMENT (ожидание 40.1 c) | `…` | orderer=10 orderer2=10 orderer3=— orderer4=— peer0.org1=10 peer0.org2=10 |
| E8 | docker start orderer4 + orderer3, транзакция | 4/4 | да | VALID | `ccfd928505c6e82a…` | orderer=11 orderer2=11 orderer3=11 orderer4=11 peer0.org1=11 peer0.org2=11 |

Транзакция E7 после восстановления кворума: `PaymentOrderExists(PO-BFT-E7-123244) = false`.

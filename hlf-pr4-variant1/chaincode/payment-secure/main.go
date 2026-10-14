// Chaincode "paymentsecure" v1.0 — hardened PaymentOrder lifecycle with role-based access control,
// four-eyes approval and confidential settlement details in a private data collection.
// PR4, variant 1 "Banking operations", task 2.
package main

import (
	"log"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/paymentsecure/chaincode"
)

func main() {
	cc, err := contractapi.NewChaincode(&chaincode.SmartContract{})
	if err != nil {
		log.Panicf("error creating paymentsecure chaincode: %v", err)
	}
	cc.Info.Title = "paymentsecure"
	cc.Info.Version = "1.0"
	if err := cc.Start(); err != nil {
		log.Panicf("error starting paymentsecure chaincode: %v", err)
	}
}

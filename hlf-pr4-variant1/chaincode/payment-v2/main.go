// Chaincode "payment" v2.0 — PaymentOrder lifecycle between a sender bank (Org1MSP)
// and a receiver bank (Org2MSP). PR4, variant 1 "Banking operations".
package main

import (
	"log"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/payment/chaincode"
)

func main() {
	cc, err := contractapi.NewChaincode(&chaincode.SmartContract{})
	if err != nil {
		log.Panicf("error creating payment chaincode: %v", err)
	}
	cc.Info.Title = "payment"
	cc.Info.Version = "2.0"
	if err := cc.Start(); err != nil {
		log.Panicf("error starting payment chaincode: %v", err)
	}
}

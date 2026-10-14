//lint:file-ignore U1000 interfaces exist only as go:generate inputs for counterfeiter fakes

package chaincode_test

// Counterfeiter fakes (same approach as fabric-samples/asset-transfer-basic/chaincode-go/chaincode/mocks).
// Regenerate with: go generate ./...

import (
	"github.com/hyperledger/fabric-chaincode-go/v2/pkg/cid"
	"github.com/hyperledger/fabric-chaincode-go/v2/shim"
	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
)

//go:generate counterfeiter -o mocks/transaction.go -fake-name TransactionContext . transactionContext
type transactionContext interface { //nolint:unused
	contractapi.TransactionContextInterface
}

//go:generate counterfeiter -o mocks/chaincodestub.go -fake-name ChaincodeStub . chaincodeStub
type chaincodeStub interface { //nolint:unused
	shim.ChaincodeStubInterface
}

//go:generate counterfeiter -o mocks/statequeryiterator.go -fake-name StateQueryIterator . stateQueryIterator
type stateQueryIterator interface { //nolint:unused
	shim.StateQueryIteratorInterface
}

//go:generate counterfeiter -o mocks/historyqueryiterator.go -fake-name HistoryQueryIterator . historyQueryIterator
type historyQueryIterator interface { //nolint:unused
	shim.HistoryQueryIteratorInterface
}

//go:generate counterfeiter -o mocks/clientidentity.go -fake-name ClientIdentity . clientIdentity
type clientIdentity interface { //nolint:unused
	cid.ClientIdentity
}

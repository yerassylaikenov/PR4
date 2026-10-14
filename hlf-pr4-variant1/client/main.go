// payment-client — minimal Fabric Gateway client (gRPC + TLS) for the PR4 variant 1 chaincodes.
// Based on fabric-samples/asset-transfer-basic/application-gateway-go.
//
// Usage:
//
//	payment-client [-org 1|2] [-user Admin] [-channel paymentchannel]
//	               [-transient key=@file] [-endorsing-orgs Org1MSP] submit|evaluate <chaincode> <fn> [args...]
//
// The private key is read from the MSP keystore for signing only; it is never printed or logged.
package main

import (
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hyperledger/fabric-gateway/pkg/client"
	"github.com/hyperledger/fabric-gateway/pkg/hash"
	"github.com/hyperledger/fabric-gateway/pkg/identity"
	"github.com/hyperledger/fabric-protos-go-apiv2/gateway"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
)

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

func main() {
	org := flag.Int("org", 1, "organisation number (1 = Sender Bank, 2 = Receiver Bank)")
	user := flag.String("user", "Admin", "user name under users/<user>@orgN.example.com")
	channel := flag.String("channel", "paymentchannel", "channel name")
	endorsing := flag.String("endorsing-orgs", "", "comma separated MSP IDs to endorse (e.g. Org1MSP for private-only writes)")
	var transient multiFlag
	flag.Var(&transient, "transient", "transient field key=@file or key=value (repeatable)")
	flag.Parse()

	if flag.NArg() < 3 {
		fmt.Fprintln(os.Stderr, "usage: payment-client [flags] submit|evaluate <chaincode> <function> [args...]")
		os.Exit(2)
	}
	mode, ccName, fn, args := flag.Arg(0), flag.Arg(1), flag.Arg(2), flag.Args()[3:]

	root := os.Getenv("ROOT")
	if root == "" {
		exe, _ := os.Executable()
		root = filepath.Dir(filepath.Dir(exe))
	}
	domain := fmt.Sprintf("org%d.example.com", *org)
	orgDir := filepath.Join(root, "fabric-samples/test-network/organizations/peerOrganizations", domain)
	mspID := fmt.Sprintf("Org%dMSP", *org)
	port := map[int]string{1: "7051", 2: "9051"}[*org]
	peerHost := "peer0." + domain

	conn := newGrpcConnection(filepath.Join(orgDir, "peers", peerHost, "tls", "ca.crt"), "localhost:"+port, peerHost)
	defer conn.Close()
	userMSP := filepath.Join(orgDir, "users", *user+"@"+domain, "msp")
	id := newIdentity(filepath.Join(userMSP, "signcerts"), mspID)
	sign := newSign(filepath.Join(userMSP, "keystore"))

	gw, err := client.Connect(id, client.WithSign(sign), client.WithHash(hash.SHA256), client.WithClientConnection(conn),
		client.WithEvaluateTimeout(10*time.Second), client.WithEndorseTimeout(30*time.Second),
		client.WithSubmitTimeout(10*time.Second), client.WithCommitStatusTimeout(time.Minute))
	if err != nil {
		fail(err)
	}
	defer gw.Close()
	contract := gw.GetNetwork(*channel).GetContract(ccName)

	opts := []client.ProposalOption{client.WithArguments(args...)}
	if len(transient) > 0 {
		opts = append(opts, client.WithTransient(parseTransient(transient)))
	}
	if *endorsing != "" {
		opts = append(opts, client.WithEndorsingOrganizations(strings.Split(*endorsing, ",")...))
	}

	fmt.Printf("Gateway   : %s (gRPC+TLS, %s)\n", peerHost, "localhost:"+port)
	fmt.Printf("Identity  : %s / %s\n", mspID, *user)
	fmt.Printf("Call      : %s %s.%s(%s)\n", mode, ccName, fn, strings.Join(args, ", "))
	if len(transient) > 0 {
		fmt.Printf("Transient : keys=%s (values not printed)\n", transientKeys(transient))
	}

	proposal, err := contract.NewProposal(fn, opts...)
	if err != nil {
		fail(err)
	}
	switch mode {
	case "evaluate":
		res, err := proposal.Evaluate()
		if err != nil {
			fail(err)
		}
		fmt.Printf("Result    : %s\n", res)
	case "submit":
		txn, err := proposal.Endorse()
		if err != nil {
			fail(err)
		}
		fmt.Printf("TxID      : %s\n", txn.TransactionID())
		commit, err := txn.Submit()
		if err != nil {
			fail(err)
		}
		st, err := commit.Status()
		if err != nil {
			fail(err)
		}
		fmt.Printf("Status    : %s (code %d)\n", st.Code, int32(st.Code))
		fmt.Printf("Block     : %d\n", st.BlockNumber)
		fmt.Printf("Result    : %s\n", txn.Result())
		if !st.Successful {
			os.Exit(1)
		}
	default:
		fail(fmt.Errorf("unknown mode %q", mode))
	}
}

func parseTransient(items []string) map[string][]byte {
	out := map[string][]byte{}
	for _, it := range items {
		k, v, ok := strings.Cut(it, "=")
		if !ok {
			fail(fmt.Errorf("transient must be key=value or key=@file"))
		}
		if strings.HasPrefix(v, "@") {
			b, err := os.ReadFile(strings.TrimPrefix(v, "@")) // #nosec G304 -- path supplied by the operator
			if err != nil {
				fail(err)
			}
			out[k] = b
		} else {
			out[k] = []byte(v)
		}
	}
	return out
}

func transientKeys(items []string) string {
	keys := make([]string, 0, len(items))
	for _, it := range items {
		k, _, _ := strings.Cut(it, "=")
		keys = append(keys, k)
	}
	return strings.Join(keys, ",")
}

func newGrpcConnection(tlsCertPath, endpoint, override string) *grpc.ClientConn {
	pem, err := os.ReadFile(tlsCertPath) // #nosec G304 -- fixed test-network layout
	if err != nil {
		fail(err)
	}
	cert, err := identity.CertificateFromPEM(pem)
	if err != nil {
		fail(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	conn, err := grpc.NewClient(endpoint, grpc.WithTransportCredentials(credentials.NewClientTLSFromCert(pool, override)))
	if err != nil {
		fail(err)
	}
	return conn
}

func newIdentity(certDir, mspID string) *identity.X509Identity {
	pem, err := readFirstFile(certDir)
	if err != nil {
		fail(err)
	}
	cert, err := identity.CertificateFromPEM(pem)
	if err != nil {
		fail(err)
	}
	id, err := identity.NewX509Identity(mspID, cert)
	if err != nil {
		fail(err)
	}
	return id
}

func newSign(keyDir string) identity.Sign {
	pem, err := readFirstFile(keyDir)
	if err != nil {
		fail(errors.New("cannot read private key from keystore")) // never echo the path contents
	}
	key, err := identity.PrivateKeyFromPEM(pem)
	if err != nil {
		fail(errors.New("invalid private key in keystore"))
	}
	sign, err := identity.NewPrivateKeySign(key)
	if err != nil {
		fail(err)
	}
	return sign
}

func readFirstFile(dir string) ([]byte, error) {
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) == 0 {
		return nil, fmt.Errorf("no files in %s", filepath.Base(dir))
	}
	return os.ReadFile(filepath.Join(dir, entries[0].Name())) // #nosec G304 -- MSP directory
}

// fail prints gateway error details (per-peer messages) and exits with code 1.
func fail(err error) {
	fmt.Fprintf(os.Stderr, "ERROR     : %v\n", err)
	if st := status.Convert(err); st != nil {
		for _, d := range st.Details() {
			if ed, ok := d.(*gateway.ErrorDetail); ok {
				fmt.Fprintf(os.Stderr, "  peer %s (%s): %s\n", ed.GetAddress(), ed.GetMspId(), ed.GetMessage())
			}
		}
	}
	var cse *client.CommitStatusError
	if errors.As(err, &cse) {
		fmt.Fprintf(os.Stderr, "  TxID: %s\n", cse.TransactionID)
	}
	os.Exit(1)
}

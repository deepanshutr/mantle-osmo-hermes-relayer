// mantle-rpc-proxy: a thin reverse proxy in front of publicnode's
// AssetMantle RPC that rewrites the /status validator_info field so
// hermes 1.13's serde parser doesn't reject the all-zero Secp256k1 stub.
//
// Why publicnode and not polkachu: publicnode retains tx-index back to
// at least h=16893918 (the oldest unrelayed packet's send tx). polkachu
// prunes tx-index to ~last 100k blocks. Hermes needs the older index
// for `tx_search` to find send_packet events and build MsgTimeout for
// the 408 mantle orphans whose timeout has expired.
//
// The stub: publicnode's /status returns an all-zero Secp256k1 pubkey
// for "validator_info" (load-balancer fronting multiple nodes — they
// hide validator identity by stubbing). Hermes' serde parser rejects
// it with "invalid secp256k1 key at line 1 column 1108" before any
// chain logic runs. Every other endpoint (/validators, /commit,
// /tx_search, /tx, /abci_info, /block, /block_results, etc.) returns
// real data.
//
// We replace ONLY validator_info with a valid Ed25519 pubkey
// (synthesized — not a real validator's). Hermes parses successfully
// and proceeds. Hermes never uses /status's pub_key for trust;
// trust comes from the Tendermint light-client header verification
// using the actual validator set returned by /validators.
//
// Run:
//   go build -o mantle-rpc-proxy main.go
//   ./mantle-rpc-proxy -addr 127.0.0.1:18903

package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
)

const upstream = "https://assetmantle-rpc.publicnode.com"

// A real Ed25519 pubkey from the actual mantle-1 validator set
// (queried 2026-04-28 via /validators). Hermes treats this as opaque
// after parsing — it doesn't sign-verify against this single value.
const fakeEd25519Pubkey = "hA/LE8UsJDFlhPiGME9Vxv6oiTz7XdYIeGyVsLGhe5g="

func main() {
	addr := flag.String("addr", "127.0.0.1:18903", "listen address")
	flag.Parse()

	u, err := url.Parse(upstream)
	if err != nil {
		log.Fatalf("parse upstream: %v", err)
	}
	proxy := httputil.NewSingleHostReverseProxy(u)

	// Override Director to set Host header correctly (TLS SNI + virtual hosting).
	// Also stash JSON-RPC method on request header for ModifyResponse: hermes
	// sends `POST /` with `{"method":"status",...}` in the body, so we can't
	// detect the status request from URL path alone.
	origDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		origDirector(req)
		req.Host = u.Host
		if req.Method == "POST" && req.Body != nil {
			body, _ := io.ReadAll(req.Body)
			req.Body = io.NopCloser(bytes.NewReader(body))
			req.ContentLength = int64(len(body))
			var rpc struct {
				Method string `json:"method"`
			}
			if json.Unmarshal(body, &rpc) == nil {
				req.Header.Set("X-Proxy-Rpc-Method", rpc.Method)
			}
		}
	}

	proxy.ModifyResponse = func(resp *http.Response) error {
		isStatus := resp.Request.URL.Path == "/status" ||
			resp.Request.Header.Get("X-Proxy-Rpc-Method") == "status"
		if !isStatus {
			return nil
		}
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return err
		}

		var data map[string]interface{}
		if err := json.Unmarshal(body, &data); err != nil {
			// non-JSON or upstream error — pass through unchanged
			resp.Body = io.NopCloser(bytes.NewReader(body))
			return nil
		}

		if result, ok := data["result"].(map[string]interface{}); ok {
			if vi, ok := result["validator_info"].(map[string]interface{}); ok {
				vi["pub_key"] = map[string]interface{}{
					"type":  "tendermint/PubKeyEd25519",
					"value": fakeEd25519Pubkey,
				}
			}
		}

		modified, err := json.Marshal(data)
		if err != nil {
			resp.Body = io.NopCloser(bytes.NewReader(body))
			return nil
		}
		resp.Body = io.NopCloser(bytes.NewReader(modified))
		resp.ContentLength = int64(len(modified))
		resp.Header.Set("Content-Length", strconv.Itoa(len(modified)))
		return nil
	}

	log.Printf("mantle-rpc-proxy listening on %s → %s", *addr, upstream)
	log.Printf("only /status validator_info is rewritten; everything else is passthrough")
	if err := http.ListenAndServe(*addr, proxy); err != nil {
		log.Fatal(err)
	}
}

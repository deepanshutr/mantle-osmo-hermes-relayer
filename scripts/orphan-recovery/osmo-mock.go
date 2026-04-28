// osmo-mock: a reverse proxy that synthesizes write_acknowledgement
// tx_search responses for known orphan sequences whose write_ack tx was
// pruned from osmosis tx-index. For all other queries, passthrough to
// real osmosis RPC.
//
// Why: osmosis public RPCs prune tx-index aggressively. Hermes' tx packet-ack
// requires fetching write_ack events from osmosis tx-index. For 25 mantle
// commits whose ack value is the standard `{"result":"AQ=="}`, we can
// synthesize the response and bypass the missing tx-index.

package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
)

const upstream = "https://osmosis.rpc.kjnodes.com"

// Standard success ack hash matches sha256({"result":"AQ=="}).
const standardAckJSON = `{"result":"AQ=="}`

// Loaded from packets.jsonl: seq -> packet event attributes (b64-decoded).
type Packet struct {
	Sequence              string `json:"packet_sequence"`
	SrcPort               string `json:"packet_src_port"`
	SrcChannel            string `json:"packet_src_channel"`
	DstPort               string `json:"packet_dst_port"`
	DstChannel            string `json:"packet_dst_channel"`
	Data                  string `json:"packet_data"`
	DataHex               string `json:"packet_data_hex"`
	TimeoutHeight         string `json:"packet_timeout_height"`
	TimeoutTimestamp      string `json:"packet_timeout_timestamp"`
	ChannelOrdering       string `json:"packet_channel_ordering"`
	Connection            string `json:"packet_connection"`
	Hash                  string `json:"hash"`
	Height                string `json:"height"`
	Seq                   string `json:"seq"`
}

var packetsBySeq = map[string]*Packet{}

func b64(s string) string {
	return base64.StdEncoding.EncodeToString([]byte(s))
}

// Build a write_acknowledgement event with the correct ack value for this packet.
// CometBFT 0.38 returns plain strings (not base64) in event attributes.
func buildWriteAckEvent(p *Packet) map[string]interface{} {
	ackJSON := ackForPacket(p)
	attrs := []map[string]interface{}{
		{"key": "packet_data", "value": p.Data, "index": true},
		{"key": "packet_data_hex", "value": p.DataHex, "index": true},
		{"key": "packet_timeout_height", "value": p.TimeoutHeight, "index": true},
		{"key": "packet_timeout_timestamp", "value": p.TimeoutTimestamp, "index": true},
		{"key": "packet_sequence", "value": p.Sequence, "index": true},
		{"key": "packet_src_port", "value": p.SrcPort, "index": true},
		{"key": "packet_src_channel", "value": p.SrcChannel, "index": true},
		{"key": "packet_dst_port", "value": p.DstPort, "index": true},
		{"key": "packet_dst_channel", "value": p.DstChannel, "index": true},
		{"key": "packet_channel_ordering", "value": p.ChannelOrdering, "index": true},
		{"key": "packet_connection", "value": p.Connection, "index": true},
		{"key": "packet_ack", "value": ackJSON, "index": true},
		{"key": "packet_ack_hex", "value": toHex([]byte(ackJSON)), "index": true},
	}
	return map[string]interface{}{
		"type":       "write_acknowledgement",
		"attributes": attrs,
	}
}

// Standard success ack {"result":"AQ=="}, hash matches CPdVftUYJv4Y2EUSvyTsdQAe268hI6R333KgqfNkCnw=
const standardAckJSON_const = `{"result":"AQ=="}`

// ibc-hooks wrapped ack from successful Skip swap_and_action with no contract_result.
// Hash matches sKUjStaDGzewwup3y3ojsSrpKVNTSJPz8Cf9yt3VI4g=
const wasmAckJSON_const = `{"result":"eyJjb250cmFjdF9yZXN1bHQiOm51bGwsImliY19hY2siOiJleUp5WlhOMWJIUWlPaUpCVVQwOUluMD0ifQ=="}`

// 20 mantle seqs known to use the wasm ack format.
var wasmAckSeqs = map[string]bool{
	"216389": true, "216679": true, "216839": true, "216991": true, "218759": true,
	"219140": true, "219863": true, "219921": true, "219922": true, "219923": true,
	"219924": true, "219926": true, "219927": true, "219928": true, "219939": true,
	"220160": true, "220433": true, "220434": true, "222279": true, "222646": true,
}

func ackForPacket(p *Packet) string {
	if wasmAckSeqs[p.Seq] {
		return wasmAckJSON_const
	}
	return standardAckJSON_const
}

func toHex(b []byte) string {
	return strings.ToLower(fmt.Sprintf("%x", b))
}

// Synthesize a tx_search JSON-RPC response for a single write_ack event.
// Hermes uses the height field to call abci_query for proof; we use latest
// (height=0) which becomes "use latest" downstream — but tendermint requires
// a specific height. We pass the original send_packet height as a placeholder;
// it doesn't have to be the actual write_ack height because the proof is
// fetched separately at consensus_height of the dst client.
func synthesizeTxSearchResp(rpcID json.RawMessage, p *Packet) []byte {
	heightInt, _ := strconv.ParseInt(p.Height, 10, 64)
	// Minimal proto-encoded Tx: empty body+auth_info+empty signatures.
	// Hex: 0a00 1200 (body=empty, auth_info=empty). Wrapped TxRaw needs body_bytes/auth_info_bytes/signatures.
	// TxRaw proto: field 1 (body_bytes) = bytes "" → 0a00; field 2 (auth_info_bytes) = bytes "" → 1200; field 3 signatures = none.
	// Result: 0x0a001200 → 4-byte tx, base64 = CgASAA==
	fakeTx := "CgASAA=="
	tx := map[string]interface{}{
		"hash":   p.Hash,
		"height": fmt.Sprintf("%d", heightInt),
		"index":  0,
		"tx_result": map[string]interface{}{
			"code":       0,
			"data":       "",
			"log":        "",
			"info":       "",
			"gas_wanted": "0",
			"gas_used":   "0",
			"events":     []map[string]interface{}{buildWriteAckEvent(p)},
			"codespace":  "",
		},
		"tx": fakeTx,
	}
	resp := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      rpcID,
		"result": map[string]interface{}{
			"txs":         []map[string]interface{}{tx},
			"total_count": "1",
		},
	}
	b, _ := json.Marshal(resp)
	return b
}

// Match write_acknowledgement.packet_sequence='X' or unquoted X.
var seqRE = regexp.MustCompile(`write_acknowledgement\.packet_sequence\s*=\s*'?(\d+)'?`)

func parseSeqFromQuery(q string) string {
	m := seqRE.FindStringSubmatch(q)
	if len(m) == 2 {
		return m[1]
	}
	return ""
}

// Synthetic height: use a recent osmosis height to avoid hermes filtering
// by chain freshness. Each packet gets unique offset from base.
var baseHeight int64 = 60443900

func syntheticHeight(p *Packet) int64 {
	seq, _ := strconv.ParseInt(p.Seq, 10, 64)
	return baseHeight - 100000 + seq%100000
}

// Synthesize block_search response: one block at synthetic height.
func synthesizeBlockSearchResp(rpcID json.RawMessage, p *Packet) []byte {
	h := syntheticHeight(p)
	hStr := fmt.Sprintf("%d", h)
	block := map[string]interface{}{
		"block_id": map[string]interface{}{
			"hash": "0000000000000000000000000000000000000000000000000000000000000000",
			"parts": map[string]interface{}{
				"total": 1,
				"hash":  "0000000000000000000000000000000000000000000000000000000000000000",
			},
		},
		"block": map[string]interface{}{
			"header": map[string]interface{}{
				"version":             map[string]interface{}{"block": "11", "app": "0"},
				"chain_id":            "osmosis-1",
				"height":              hStr,
				"time":                "2026-01-15T00:00:00Z",
				"last_block_id":       map[string]interface{}{"hash": "", "parts": map[string]interface{}{"total": 0, "hash": ""}},
				"last_commit_hash":    "",
				"data_hash":           "",
				"validators_hash":     "",
				"next_validators_hash": "",
				"consensus_hash":      "",
				"app_hash":            "",
				"last_results_hash":   "",
				"evidence_hash":       "",
				"proposer_address":    "0000000000000000000000000000000000000000",
			},
			"data": map[string]interface{}{"txs": []string{}},
			"evidence": map[string]interface{}{"evidence": []interface{}{}},
			"last_commit": map[string]interface{}{
				"height": "0", "round": 0,
				"block_id": map[string]interface{}{"hash": "", "parts": map[string]interface{}{"total": 0, "hash": ""}},
				"signatures": []interface{}{},
			},
		},
	}
	resp := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      rpcID,
		"result": map[string]interface{}{
			"blocks":      []map[string]interface{}{block},
			"total_count": "1",
		},
	}
	b, _ := json.Marshal(resp)
	return b
}

// Synthesize block_results response with our write_ack event in begin_block_events.
// Hermes' query_write_ack_packet_events extracts events from tx_results, begin_block_events, end_block_events.
func synthesizeBlockResultsResp(rpcID json.RawMessage, p *Packet) []byte {
	h := syntheticHeight(p)
	hStr := fmt.Sprintf("%d", h)
	// Return ALL three: begin_block_events (v0.34), end_block_events (v0.34), finalize_block_events (v0.38)
	// AND a tx in txs_results so it's parseable from any compat mode.
	resp := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      rpcID,
		"result": map[string]interface{}{
			"height":                  hStr,
			"txs_results":             []map[string]interface{}{
				{
					"code":       0,
					"data":       "",
					"log":        "",
					"info":       "",
					"gas_wanted": "0",
					"gas_used":   "0",
					"events":     []map[string]interface{}{buildWriteAckEvent(p)},
					"codespace":  "",
				},
			},
			"begin_block_events":      []map[string]interface{}{buildWriteAckEvent(p)},
			"end_block_events":        []map[string]interface{}{buildWriteAckEvent(p)},
			"finalize_block_events":   []map[string]interface{}{buildWriteAckEvent(p)},
			"validator_updates":       []interface{}{},
			"consensus_param_updates": nil,
			"app_hash":                "",
		},
	}
	b, _ := json.Marshal(resp)
	return b
}

// Track which heights we've synthesized — block_results queries for those go to mock.
var heightToPacket = map[string]*Packet{}

func loadPackets(path string) {
	f, err := os.Open(path)
	if err != nil {
		log.Fatalf("open packets: %v", err)
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	for scanner.Scan() {
		var p Packet
		if err := json.Unmarshal(scanner.Bytes(), &p); err != nil {
			log.Printf("skip bad line: %v", err)
			continue
		}
		if p.Sequence != "" {
			packetsBySeq[p.Sequence] = &p
		}
	}
	log.Printf("loaded %d packets", len(packetsBySeq))
}

func main() {
	addr := flag.String("addr", "0.0.0.0:18905", "")
	pktFile := flag.String("packets", "/tmp/orphan/packets.jsonl", "")
	flag.Parse()
	loadPackets(*pktFile)

	u, _ := url.Parse(upstream)
	proxy := httputil.NewSingleHostReverseProxy(u)
	orig := proxy.Director
	proxy.Director = func(req *http.Request) {
		orig(req)
		req.Host = u.Host
	}

	intercepted := func(w http.ResponseWriter, r *http.Request) bool {
		// /tx_search?query=... or /block_search?query=...
		if r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/tx_search") {
			q := strings.Trim(r.URL.Query().Get("query"), `"`)
			seq := parseSeqFromQuery(q)
			if p, ok := packetsBySeq[seq]; ok && strings.Contains(q, "write_acknowledgement") {
				w.Header().Set("Content-Type", "application/json")
				w.Write(synthesizeTxSearchResp(json.RawMessage(`-1`), p))
				log.Printf("INTERCEPT GET tx_search seq=%s", seq)
				return true
			}
		}
		if r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/block_search") {
			q := strings.Trim(r.URL.Query().Get("query"), `"`)
			seq := parseSeqFromQuery(q)
			if p, ok := packetsBySeq[seq]; ok && strings.Contains(q, "write_acknowledgement") {
				heightToPacket[fmt.Sprintf("%d", syntheticHeight(p))] = p
				w.Header().Set("Content-Type", "application/json")
				w.Write(synthesizeBlockSearchResp(json.RawMessage(`-1`), p))
				log.Printf("INTERCEPT GET block_search seq=%s", seq)
				return true
			}
		}
		if r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/block_results") {
			h := r.URL.Query().Get("height")
			if p, ok := heightToPacket[h]; ok {
				w.Header().Set("Content-Type", "application/json")
				w.Write(synthesizeBlockResultsResp(json.RawMessage(`-1`), p))
				log.Printf("INTERCEPT GET block_results height=%s", h)
				return true
			}
		}
		// POST / with JSON-RPC method dispatch
		if r.Method == "POST" {
			body, _ := io.ReadAll(r.Body)
			r.Body = io.NopCloser(bytes.NewReader(body))
			var req struct {
				ID     json.RawMessage `json:"id"`
				Method string          `json:"method"`
				Params struct {
					Query  string `json:"query"`
					Height string `json:"height"`
				} `json:"params"`
			}
			if json.Unmarshal(body, &req) == nil {
				switch req.Method {
				case "tx_search":
					seq := parseSeqFromQuery(req.Params.Query)
					if p, ok := packetsBySeq[seq]; ok && strings.Contains(req.Params.Query, "write_acknowledgement") {
						w.Header().Set("Content-Type", "application/json")
						w.Write(synthesizeTxSearchResp(req.ID, p))
						log.Printf("INTERCEPT POST tx_search seq=%s", seq)
						return true
					}
				case "block_search":
					seq := parseSeqFromQuery(req.Params.Query)
					if p, ok := packetsBySeq[seq]; ok && strings.Contains(req.Params.Query, "write_acknowledgement") {
						heightToPacket[fmt.Sprintf("%d", syntheticHeight(p))] = p
						w.Header().Set("Content-Type", "application/json")
						w.Write(synthesizeBlockSearchResp(req.ID, p))
						log.Printf("INTERCEPT POST block_search seq=%s", seq)
						return true
					}
				case "block_results":
					if p, ok := heightToPacket[req.Params.Height]; ok {
						w.Header().Set("Content-Type", "application/json")
						w.Write(synthesizeBlockResultsResp(req.ID, p))
						log.Printf("INTERCEPT POST block_results height=%s", req.Params.Height)
						return true
					}
				}
			}
		}
		return false
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if intercepted(w, r) {
			return
		}
		proxy.ServeHTTP(w, r)
	})
	log.Printf("osmo-mock listening %s -> %s; %d synthesizable seqs", *addr, upstream, len(packetsBySeq))
	if err := http.ListenAndServe(*addr, mux); err != nil {
		log.Fatal(err)
	}
}

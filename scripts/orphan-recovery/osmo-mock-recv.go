// osmo-mock-recv: synthesizes send_packet tx_search/block_search/block_results
// responses for known orphan sequences whose original send_packet tx is past
// public RPCs' tx-index horizon. Passthrough for everything else.
//
// Why: 52 osmo->mantle "unreceived" packets are stuck because hermes
// can't find the send_packet event via tx_search. The IBC packet commitment
// itself still exists on osmosis at the current height (commitments persist
// until ack/timeout) so the merkle proof can be served from current state via
// passthrough — only the event payload needs to be synthesized.
//
// Use:
//   go build -o osmo-mock-recv osmo-mock-recv.go
//   ./osmo-mock-recv -addr 0.0.0.0:18906 -packets osmo-send-packets.jsonl
//
// Then point hermes at it as the osmosis RPC and run:
//   hermes tx packet-recv --src-chain osmosis-1 --dst-chain mantle-1 \
//     --src-port transfer --src-channel channel-232 \
//     --packet-sequences <csv-of-seqs>

package main

import (
	"bufio"
	"bytes"
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

const upstream = "https://rpc.osmosis.zone"

// Loaded from packets.jsonl: seq -> send_packet event payload.
type Packet struct {
	Sequence         string `json:"packet_sequence"`
	SrcPort          string `json:"packet_src_port"`
	SrcChannel       string `json:"packet_src_channel"`
	DstPort          string `json:"packet_dst_port"`
	DstChannel       string `json:"packet_dst_channel"`
	Data             string `json:"packet_data"`
	DataHex          string `json:"packet_data_hex"`
	TimeoutHeight    string `json:"packet_timeout_height"`
	TimeoutTimestamp string `json:"packet_timeout_timestamp"`
	ChannelOrdering  string `json:"packet_channel_ordering"`
	Connection       string `json:"packet_connection"`
	Hash             string `json:"hash"`
	Height           string `json:"height"`
	Seq              string `json:"seq"`
}

var packetsBySeq = map[string]*Packet{}

func toHex(b []byte) string {
	return strings.ToLower(fmt.Sprintf("%x", b))
}

// CometBFT 0.38 returns plain strings (not base64) in event attributes.
func buildSendPacketEvent(p *Packet) map[string]interface{} {
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
	}
	return map[string]interface{}{
		"type":       "send_packet",
		"attributes": attrs,
	}
}

func synthesizeTxSearchResp(rpcID json.RawMessage, p *Packet) []byte {
	heightInt, _ := strconv.ParseInt(p.Height, 10, 64)
	// Empty proto-encoded TxRaw: body_bytes=empty, auth_info_bytes=empty.
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
			"events":     []map[string]interface{}{buildSendPacketEvent(p)},
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

// Match send_packet.packet_sequence='X' or unquoted X.
var seqRE = regexp.MustCompile(`send_packet\.packet_sequence\s*=\s*'?(\d+)'?`)

func parseSeqFromQuery(q string) string {
	m := seqRE.FindStringSubmatch(q)
	if len(m) == 2 {
		return m[1]
	}
	return ""
}

// Synthetic height: use a recent osmosis height to avoid hermes filtering by
// chain freshness. Per-packet offset by sequence number for uniqueness.
var baseHeight int64 = 60443900

func syntheticHeight(p *Packet) int64 {
	seq, _ := strconv.ParseInt(p.Seq, 10, 64)
	return baseHeight - 100000 + seq%100000
}

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
				"version":              map[string]interface{}{"block": "11", "app": "0"},
				"chain_id":             "osmosis-1",
				"height":               hStr,
				"time":                 "2026-04-15T00:00:00Z",
				"last_block_id":        map[string]interface{}{"hash": "", "parts": map[string]interface{}{"total": 0, "hash": ""}},
				"last_commit_hash":     "",
				"data_hash":            "",
				"validators_hash":      "",
				"next_validators_hash": "",
				"consensus_hash":       "",
				"app_hash":             "",
				"last_results_hash":    "",
				"evidence_hash":        "",
				"proposer_address":     "0000000000000000000000000000000000000000",
			},
			"data":     map[string]interface{}{"txs": []string{}},
			"evidence": map[string]interface{}{"evidence": []interface{}{}},
			"last_commit": map[string]interface{}{
				"height": "0", "round": 0,
				"block_id":   map[string]interface{}{"hash": "", "parts": map[string]interface{}{"total": 0, "hash": ""}},
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

// block_results returns send_packet event in tx_results, begin_block_events,
// end_block_events, and finalize_block_events for compat across CometBFT
// versions.
func synthesizeBlockResultsResp(rpcID json.RawMessage, p *Packet) []byte {
	h := syntheticHeight(p)
	hStr := fmt.Sprintf("%d", h)
	resp := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      rpcID,
		"result": map[string]interface{}{
			"height": hStr,
			"txs_results": []map[string]interface{}{
				{
					"code":       0,
					"data":       "",
					"log":        "",
					"info":       "",
					"gas_wanted": "0",
					"gas_used":   "0",
					"events":     []map[string]interface{}{buildSendPacketEvent(p)},
					"codespace":  "",
				},
			},
			"begin_block_events":      []map[string]interface{}{buildSendPacketEvent(p)},
			"end_block_events":        []map[string]interface{}{buildSendPacketEvent(p)},
			"finalize_block_events":   []map[string]interface{}{buildSendPacketEvent(p)},
			"validator_updates":       []interface{}{},
			"consensus_param_updates": nil,
			"app_hash":                "",
		},
	}
	b, _ := json.Marshal(resp)
	return b
}

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
	addr := flag.String("addr", "0.0.0.0:18906", "")
	pktFile := flag.String("packets", "/tmp/orphan4/osmo-send-packets.jsonl", "")
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
		if r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/tx_search") {
			q := strings.Trim(r.URL.Query().Get("query"), `"`)
			seq := parseSeqFromQuery(q)
			if p, ok := packetsBySeq[seq]; ok && strings.Contains(q, "send_packet") {
				w.Header().Set("Content-Type", "application/json")
				w.Write(synthesizeTxSearchResp(json.RawMessage(`-1`), p))
				log.Printf("INTERCEPT GET tx_search seq=%s", seq)
				return true
			}
		}
		if r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/block_search") {
			q := strings.Trim(r.URL.Query().Get("query"), `"`)
			seq := parseSeqFromQuery(q)
			if p, ok := packetsBySeq[seq]; ok && strings.Contains(q, "send_packet") {
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
					if p, ok := packetsBySeq[seq]; ok && strings.Contains(req.Params.Query, "send_packet") {
						w.Header().Set("Content-Type", "application/json")
						w.Write(synthesizeTxSearchResp(req.ID, p))
						log.Printf("INTERCEPT POST tx_search seq=%s", seq)
						return true
					}
				case "block_search":
					seq := parseSeqFromQuery(req.Params.Query)
					if p, ok := packetsBySeq[seq]; ok && strings.Contains(req.Params.Query, "send_packet") {
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
	log.Printf("osmo-mock-recv listening %s -> %s; %d synthesizable seqs", *addr, upstream, len(packetsBySeq))
	if err := http.ListenAndServe(*addr, mux); err != nil {
		log.Fatal(err)
	}
}

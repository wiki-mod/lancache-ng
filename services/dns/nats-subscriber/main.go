package main

import (
	"bytes"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/nats-io/nats.go"
)

type DNSRecord struct {
	Action  string                   `json:"action"`
	Zone    string                   `json:"zone"`
	Name    string                   `json:"name"`
	Type    string                   `json:"type"`
	TTL     int                      `json:"ttl"`
	Records []map[string]interface{} `json:"records"`
}

type RRset struct {
	Name       string                   `json:"name"`
	Type       string                   `json:"type"`
	TTL        int                      `json:"ttl,omitempty"`
	ChangeType string                   `json:"changetype"`
	Records    []map[string]interface{} `json:"records,omitempty"`
}

type ZoneUpdate struct {
	RRsets []RRset `json:"rrsets"`
}

type ZoneRecord struct {
	Name    string        `json:"name"`
	Type    string        `json:"type"`
	TTL     int           `json:"ttl"`
	Records []ZoneContent `json:"records"`
}

type ZoneContent struct {
	Content string `json:"content"`
	Disabled bool  `json:"disabled"`
}

type ZoneInfo struct {
	RRsets []RRset `json:"rrsets"`
}

func main() {
	natsURL := os.Getenv("NATS_URL")
	if natsURL == "" {
		natsURL = "nats://nats:4222"
	}

	natsToken := os.Getenv("NATS_TOKEN")
	natsConsumer := os.Getenv("NATS_CONSUMER")
	if natsConsumer == "" {
		log.Fatal("NATS_CONSUMER environment variable is required")
	}

	pdnsAPIKey := os.Getenv("PDNS_API_KEY")
	if pdnsAPIKey == "" {
		log.Fatal("PDNS_API_KEY environment variable is required")
	}

	natsReconciler := os.Getenv("NATS_RECONCILER")

	// Connect to NATS
	opts := []nats.Option{
		nats.MaxReconnects(-1),
		nats.ReconnectWait(3 * time.Second),
	}

	if natsToken != "" {
		opts = append(opts, nats.Token(natsToken))
	}

	nc, err := nats.Connect(natsURL, opts...)
	if err != nil {
		log.Fatalf("Failed to connect to NATS: %v", err)
	}
	defer nc.Close()

	log.Printf("Connected to NATS at %s", natsURL)

	// Get JetStream context
	js, err := nc.JetStream()
	if err != nil {
		log.Fatalf("Failed to get JetStream context: %v", err)
	}

	// Create or update stream LANCACHE_DNS
	streamInfo, err := js.StreamInfo("LANCACHE_DNS")
	if err != nil && err != nats.ErrStreamNotFound {
		log.Fatalf("Failed to get stream info: %v", err)
	}

	if streamInfo == nil {
		// Create stream
		_, err = js.AddStream(&nats.StreamConfig{
			Name:       "LANCACHE_DNS",
			Subjects:   []string{"lancache.dns.>"},
			Storage:    nats.FileStorage,
			MaxAge:     7 * 24 * time.Hour,
			Discard:    nats.DiscardOld,
			NoAck:      false,
			Retention:  nats.LimitsPolicy,
		})
		if err != nil {
			log.Fatalf("Failed to create stream: %v", err)
		}
		log.Println("Created stream LANCACHE_DNS")
	}

	// Create durable pull subscriber
	sub, err := js.PullSubscribe("lancache.dns.>", natsConsumer, nats.BindStream("LANCACHE_DNS"))
	if err != nil {
		log.Fatalf("Failed to subscribe: %v", err)
	}
	log.Printf("Created durable subscriber: %s", natsConsumer)

	// Start reconciler if enabled
	if natsReconciler == "1" {
		go reconciler(js, pdnsAPIKey)
	}

	// Main message loop
	for {
		msgs, err := sub.Fetch(10, nats.MaxWait(5*time.Second))
		if err != nil && err != nats.ErrTimeout {
			log.Printf("Error fetching messages: %v", err)
			continue
		}

		for _, msg := range msgs {
			handleMessage(msg, pdnsAPIKey)
			err := msg.Ack()
			if err != nil {
				log.Printf("Error acknowledging message: %v", err)
			}
		}
	}
}

func handleMessage(msg *nats.Msg, pdnsAPIKey string) {
	subject := msg.Subject

	if strings.HasPrefix(subject, "lancache.dns.heartbeat") {
		// Ignore heartbeat messages
		return
	}

	if subject == "lancache.dns.record" {
		handleDNSRecord(msg, pdnsAPIKey)
		return
	}

	if subject == "lancache.dns.flush" {
		handleDNSFlush(pdnsAPIKey)
		return
	}

	log.Printf("Unknown subject: %s", subject)
}

func handleDNSRecord(msg *nats.Msg, pdnsAPIKey string) {
	var record DNSRecord
	err := json.Unmarshal(msg.Data, &record)
	if err != nil {
		log.Printf("Error parsing DNS record: %v", err)
		return
	}

	rrset := RRset{
		Name:       record.Name,
		Type:       record.Type,
		ChangeType: "REPLACE",
	}

	if record.Action == "delete" {
		rrset.ChangeType = "DELETE"
	} else if record.Action == "replace" {
		rrset.TTL = record.TTL
		rrset.Records = record.Records
	}

	update := ZoneUpdate{
		RRsets: []RRset{rrset},
	}

	payload, err := json.Marshal(update)
	if err != nil {
		log.Printf("Error marshaling PATCH payload: %v", err)
		return
	}

	url := "http://127.0.0.1:8081/api/v1/servers/localhost/zones/" + record.Zone

	req, err := http.NewRequest("PATCH", url, bytes.NewBuffer(payload))
	if err != nil {
		log.Printf("Error creating PATCH request: %v", err)
		return
	}

	req.Header.Set("X-API-Key", pdnsAPIKey)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("Error sending PATCH request: %v", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		log.Printf("PDNS error: %d %s for zone=%s name=%s type=%s", resp.StatusCode, resp.Status, record.Zone, record.Name, record.Type)
	} else {
		log.Printf("Updated DNS record: zone=%s name=%s type=%s action=%s", record.Zone, record.Name, record.Type, record.Action)
	}
}

func handleDNSFlush(pdnsAPIKey string) {
	url := "http://127.0.0.1:8082/api/v1/servers/localhost/cache/flush?type=packet"

	req, err := http.NewRequest("PUT", url, nil)
	if err != nil {
		log.Printf("Error creating flush request: %v", err)
		return
	}

	req.Header.Set("X-API-Key", pdnsAPIKey)

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("Error sending flush request: %v", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		log.Printf("PDNS flush error: %d %s", resp.StatusCode, resp.Status)
	} else {
		log.Printf("Flushed PDNS cache")
	}
}

func reconciler(js nats.JetStreamContext, pdnsAPIKey string) {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		url := "http://127.0.0.1:8081/api/v1/servers/localhost/zones/lan"

		req, err := http.NewRequest("GET", url, nil)
		if err != nil {
			log.Printf("Reconciler: error creating GET request: %v", err)
			continue
		}

		req.Header.Set("X-API-Key", pdnsAPIKey)

		client := &http.Client{Timeout: 10 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			log.Printf("Reconciler: error fetching zone: %v", err)
			continue
		}

		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			log.Printf("Reconciler: PDNS error: %d %s", resp.StatusCode, resp.Status)
			resp.Body.Close()
			continue
		}

		var zoneInfo ZoneInfo
		err = json.NewDecoder(resp.Body).Decode(&zoneInfo)
		resp.Body.Close()
		if err != nil {
			log.Printf("Reconciler: error decoding zone info: %v", err)
			continue
		}

		for _, rrset := range zoneInfo.RRsets {
			msgID := "reconcile-lan-" + strings.TrimSuffix(rrset.Name, ".") + "-" + rrset.Type

			recordPayload := map[string]interface{}{
				"action":  "replace",
				"zone":    "lan",
				"name":    rrset.Name,
				"type":    rrset.Type,
				"ttl":     rrset.TTL,
				"records": rrset.Records,
			}

			payload, err := json.Marshal(recordPayload)
			if err != nil {
				log.Printf("Reconciler: error marshaling record: %v", err)
				continue
			}

			msg := &nats.Msg{
				Subject: "lancache.dns.record",
				Data:    payload,
				Header:  nats.Header{},
			}
			msg.Header.Set(nats.MsgIdHdr, msgID)

			_, err = js.PublishMsg(msg)
			if err != nil {
				log.Printf("Reconciler: error publishing record: %v", err)
			}
		}

		log.Printf("Reconciler: published %d records", len(zoneInfo.RRsets))
	}
}

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/gorilla/mux"
	"github.com/joho/godotenv"
)

var (
	// Configuration
	API_PORT          = getEnv("API_PORT", "8080")
	API_TOKEN         = getEnv("API_TOKEN", "your-secure-api-token") // Default if not in .env
	WG_CONFIG_FILE    = getEnv("WG_CONFIG_FILE", "/etc/wireguard/wg0.conf")
	WG_PARAMS_FILE    = getEnv("WG_PARAMS_FILE", "/etc/wireguard/params")
	WIREGUARD_CLIENTS = getEnv("WIREGUARD_CLIENTS", "/home/wireguard/users")
)

// WireGuard parameters loaded from params file
type WGParams struct {
	ServerPubIP      string
	ServerPubNIC     string
	ServerWGNIC      string
	ServerWGIPv4     string
	ServerWGIPv6     string
	ServerPort       string
	ServerPrivKey    string
	ServerPubKey     string
	ClientDNS1       string
	ClientDNS2       string
	AllowedIPs       string
}

// Response structs
type APIResponse struct {
	Success bool        `json:"success"`
	Message string      `json:"message,omitempty"`
	Data    interface{} `json:"data,omitempty"`
}

type Client struct {
	Name   string `json:"name"`
	IPV4   string `json:"ipv4,omitempty"`
	IPV6   string `json:"ipv6,omitempty"`
	Config string `json:"config,omitempty"`
}

// Add user request
type AddUserRequest struct {
	Name   string `json:"name"`
	IPV4   string `json:"ipv4,omitempty"`
	IPV6   string `json:"ipv6,omitempty"`
}

// Delete user request
type DeleteUserRequest struct {
	Name string `json:"name"`
}

// Global params
var wgParams WGParams

// Auth middleware
func authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("key")
		if token == "" {
			respondWithError(w, http.StatusUnauthorized, "Missing API token")
			return
		}

		if token != API_TOKEN {
			respondWithError(w, http.StatusUnauthorized, "Invalid API token")
			return
		}

		next.ServeHTTP(w, r)
	})
}

// Helper function to get environment variable with fallback
func getEnv(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}

// Load environment variables from .env file
func loadEnv() {
	// Load .env file if it exists
	err := godotenv.Load()
	if err != nil {
		log.Printf("No .env file found, using default configuration")
	}
	
	// Reload configuration vars after reading .env
	API_PORT = getEnv("API_PORT", "8080")
	API_TOKEN = getEnv("API_TOKEN", "your-secure-api-token")
	WG_CONFIG_FILE = getEnv("WG_CONFIG_FILE", "/etc/wireguard/wg0.conf")
	WG_PARAMS_FILE = getEnv("WG_PARAMS_FILE", "/etc/wireguard/params")
	WIREGUARD_CLIENTS = getEnv("WIREGUARD_CLIENTS", "/home/wireguard/users")
}

// Main function
func main() {
	// Load environment variables
	loadEnv()
	
	// Log configuration
	log.Printf("Starting WireGuard API server...")
	log.Printf("API port: %s", API_PORT)
	log.Printf("WireGuard config file: %s", WG_CONFIG_FILE)
	log.Printf("WireGuard params file: %s", WG_PARAMS_FILE)
	log.Printf("WireGuard clients directory: %s", WIREGUARD_CLIENTS)
	
	// Load WireGuard params
	err := loadWGParams()
	if err != nil {
		log.Fatalf("Failed to load WireGuard parameters: %v", err)
	}

	// Create router
	router := mux.NewRouter()

	// API routes
	router.HandleFunc("/api/users", listUsersHandler).Methods("GET")
	router.HandleFunc("/api/users/add", addUserHandler).Methods("POST")
	router.HandleFunc("/api/users/delete", deleteUserHandler).Methods("POST")

	// Create middleware chain
	router.Use(authMiddlewareFunc)

	// Start server
	log.Printf("WireGuard API server running on port %s", API_PORT)
	log.Fatal(http.ListenAndServe(":"+API_PORT, router))
}

// Convert the auth middleware to work with gorilla/mux
func authMiddlewareFunc(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("key")
		if token == "" {
			respondWithError(w, http.StatusUnauthorized, "Missing API token")
			return
		}

		if token != API_TOKEN {
			respondWithError(w, http.StatusUnauthorized, "Invalid API token")
			return
		}

		next.ServeHTTP(w, r)
	})
}

// Load WireGuard parameters from params file
func loadWGParams() error {
	file, err := os.Open(WG_PARAMS_FILE)
	if err != nil {
		return fmt.Errorf("failed to open params file: %v", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	params := make(map[string]string)
	
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			key := strings.TrimSpace(parts[0])
			value := strings.TrimSpace(parts[1])
			// Remove quotes if present
			value = strings.Trim(value, "\"'")
			params[key] = value
		}
	}

	wgParams = WGParams{
		ServerPubIP:   params["SERVER_PUB_IP"],
		ServerPubNIC:  params["SERVER_PUB_NIC"],
		ServerWGNIC:   params["SERVER_WG_NIC"],
		ServerWGIPv4:  params["SERVER_WG_IPV4"],
		ServerWGIPv6:  params["SERVER_WG_IPV6"],
		ServerPort:    params["SERVER_PORT"],
		ServerPrivKey: params["SERVER_PRIV_KEY"],
		ServerPubKey:  params["SERVER_PUB_KEY"],
		ClientDNS1:    params["CLIENT_DNS_1"],
		ClientDNS2:    params["CLIENT_DNS_2"],
		AllowedIPs:    params["ALLOWED_IPS"],
	}

	// Ensure all required fields are present
	if wgParams.ServerPubIP == "" || wgParams.ServerWGNIC == "" || 
	   wgParams.ServerPubKey == "" || wgParams.ServerPort == "" || 
	   wgParams.ServerWGIPv4 == "" {
		return fmt.Errorf("required WireGuard parameters missing")
	}

	return nil
}

// Handler for listing all users
func listUsersHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		respondWithError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}

	clients, err := listWireGuardClients()
	if err != nil {
		respondWithError(w, http.StatusInternalServerError, err.Error())
		return
	}

	respondWithJSON(w, http.StatusOK, APIResponse{
		Success: true,
		Data:    clients,
	})
}

// Handler for adding a new user
func addUserHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		respondWithError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}

	var req AddUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondWithError(w, http.StatusBadRequest, "Invalid request payload")
		return
	}

	// Validate client name
	nameRegex := regexp.MustCompile(`^[a-zA-Z0-9_-]{1,15}$`)
	if !nameRegex.MatchString(req.Name) {
		respondWithError(w, http.StatusBadRequest, "Client name must contain only alphanumeric characters, underscores, or dashes and be less than 16 characters")
		return
	}

	// Check if client already exists
	exists, err := clientExists(req.Name)
	if err != nil {
		respondWithError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if exists {
		respondWithError(w, http.StatusConflict, "A client with this name already exists")
		return
	}

	// Auto-assign IPV4 if not provided
	ipv4 := req.IPV4
	if ipv4 == "" {
		ipv4, err = getNextAvailableIPv4()
		if err != nil {
			respondWithError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}

	// Auto-assign IPV6 if not provided and IPV6 is enabled
	ipv6 := req.IPV6
	if ipv6 == "" && wgParams.ServerWGIPv6 != "" {
		ipv6, err = getNextAvailableIPv6()
		if err != nil {
			respondWithError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}

	// Create the client
	clientConfig, err := addWireGuardClient(req.Name, ipv4, ipv6)
	if err != nil {
		respondWithError(w, http.StatusInternalServerError, err.Error())
		return
	}

	// Create response
	client := Client{
		Name:   req.Name,
		IPV4:   ipv4,
		IPV6:   ipv6,
		Config: clientConfig,
	}

	respondWithJSON(w, http.StatusOK, APIResponse{
		Success: true,
		Message: "Client added successfully",
		Data:    client,
	})
}

// Handler for deleting a user
func deleteUserHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		respondWithError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}

	var req DeleteUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondWithError(w, http.StatusBadRequest, "Invalid request payload")
		return
	}

	// Check if client exists
	exists, err := clientExists(req.Name)
	if err != nil {
		respondWithError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !exists {
		respondWithError(w, http.StatusNotFound, "Client not found")
		return
	}

	// Delete the client
	if err := deleteWireGuardClient(req.Name); err != nil {
		respondWithError(w, http.StatusInternalServerError, err.Error())
		return
	}

	respondWithJSON(w, http.StatusOK, APIResponse{
		Success: true,
		Message: "Client deleted successfully",
	})
}

// Get the next available IPv4 address
func getNextAvailableIPv4() (string, error) {
	// Parse the server IP to get the base network
	parts := strings.Split(wgParams.ServerWGIPv4, ".")
	if len(parts) != 4 {
		return "", fmt.Errorf("invalid server IPv4 address format")
	}
	
	baseIP := fmt.Sprintf("%s.%s.%s", parts[0], parts[1], parts[2])
	
	// Get existing IPs from the config file
	content, err := ioutil.ReadFile(WG_CONFIG_FILE)
	if err != nil {
		return "", fmt.Errorf("failed to read WireGuard config: %v", err)
	}
	
	// Find all IPv4 addresses in the config
	ipv4Regex := regexp.MustCompile(baseIP + `\.(\d+)`)
	matches := ipv4Regex.FindAllStringSubmatch(string(content), -1)
	
	// Collect all used last octets
	usedOctets := make(map[int]bool)
	for _, match := range matches {
		if len(match) == 2 {
			var octet int
			fmt.Sscanf(match[1], "%d", &octet)
			usedOctets[octet] = true
		}
	}
	
	// Find the first available octet starting from 2
	for i := 2; i <= 254; i++ {
		if !usedOctets[i] {
			return fmt.Sprintf("%s.%d", baseIP, i), nil
		}
	}
	
	return "", fmt.Errorf("no available IPv4 addresses in the subnet")
}

// Get the next available IPv6 address
func getNextAvailableIPv6() (string, error) {
	if wgParams.ServerWGIPv6 == "" {
		return "", nil // IPv6 not enabled
	}

	// Parse the server IP to get the base network
	parts := strings.Split(wgParams.ServerWGIPv6, "::")
	if len(parts) != 2 {
		return "", fmt.Errorf("invalid server IPv6 address format")
	}
	
	baseIP := parts[0]
	
	// Get existing IPs from the config file
	content, err := ioutil.ReadFile(WG_CONFIG_FILE)
	if err != nil {
		return "", fmt.Errorf("failed to read WireGuard config: %v", err)
	}
	
	// Find all IPv6 addresses in the config
	ipv6Regex := regexp.MustCompile(regexp.QuoteMeta(baseIP) + `::([\da-fA-F]+)`)
	matches := ipv6Regex.FindAllStringSubmatch(string(content), -1)
	
	// Collect all used last parts
	usedParts := make(map[int]bool)
	for _, match := range matches {
		if len(match) == 2 {
			var part int
			fmt.Sscanf(match[1], "%x", &part)
			usedParts[part] = true
		}
	}
	
	// Find the first available part starting from 2
	for i := 2; i <= 254; i++ {
		if !usedParts[i] {
			return fmt.Sprintf("%s::%d", baseIP, i), nil
		}
	}
	
	return "", fmt.Errorf("no available IPv6 addresses in the subnet")
}

// Check if a client with the given name exists
func clientExists(name string) (bool, error) {
	content, err := ioutil.ReadFile(WG_CONFIG_FILE)
	if err != nil {
		return false, fmt.Errorf("failed to read WireGuard config: %v", err)
	}
	
	clientRegex := regexp.MustCompile(`### Client ` + regexp.QuoteMeta(name) + `$`)
	return clientRegex.Match(content), nil
}

// List all WireGuard clients
func listWireGuardClients() ([]Client, error) {
	content, err := ioutil.ReadFile(WG_CONFIG_FILE)
	if err != nil {
		return nil, fmt.Errorf("failed to read WireGuard config: %v", err)
	}
	
	// Extract client sections
	clientRegex := regexp.MustCompile(`(?m)^### Client ([a-zA-Z0-9_-]+)$\n\[Peer\]\nPublicKey = ([a-zA-Z0-9+/=]+)\nPresharedKey = ([a-zA-Z0-9+/=]+)\nAllowedIPs = ([^,]+),(.+)$`)
	matches := clientRegex.FindAllStringSubmatch(string(content), -1)
	
	clients := make([]Client, 0, len(matches))
	for _, match := range matches {
		if len(match) >= 6 {
			client := Client{
				Name: match[1],
				IPV4: strings.TrimSuffix(match[4], "/32"),
				IPV6: strings.TrimSuffix(match[5], "/128"),
			}
			
			// Try to read config file
			configPath := filepath.Join(WIREGUARD_CLIENTS, wgParams.ServerWGNIC+"-client-"+client.Name+".conf")
			if configData, err := ioutil.ReadFile(configPath); err == nil {
				client.Config = string(configData)
			}
			
			clients = append(clients, client)
		}
	}
	
	return clients, nil
}

// Add a new WireGuard client
func addWireGuardClient(name, ipv4, ipv6 string) (string, error) {
	// Ensure the clients directory exists
	err := os.MkdirAll(WIREGUARD_CLIENTS, 0700)
	if err != nil {
		return "", fmt.Errorf("failed to create clients directory: %v", err)
	}

	// Generate key pair for the client
	privateKey, err := generatePrivateKey()
	if err != nil {
		return "", fmt.Errorf("failed to generate private key: %v", err)
	}
	
	publicKey, err := derivePublicKey(privateKey)
	if err != nil {
		return "", fmt.Errorf("failed to derive public key: %v", err)
	}
	
	preSharedKey, err := generatePSK()
	if err != nil {
		return "", fmt.Errorf("failed to generate pre-shared key: %v", err)
	}

	// Create client configuration
	endpoint := wgParams.ServerPubIP
	
	// If IPv6, add brackets if missing
	if strings.Contains(endpoint, ":") && !strings.Contains(endpoint, "[") {
		endpoint = "[" + endpoint + "]"
	}
	
	endpoint = endpoint + ":" + wgParams.ServerPort
	
	clientConfig := fmt.Sprintf(`[Interface]
PrivateKey = %s
Address = %s/32,%s/128
DNS = %s,%s

[Peer]
PublicKey = %s
PresharedKey = %s
Endpoint = %s
AllowedIPs = %s
`, privateKey, ipv4, ipv6, wgParams.ClientDNS1, wgParams.ClientDNS2,
	   wgParams.ServerPubKey, preSharedKey, endpoint, wgParams.AllowedIPs)

	// Write client config to file
	configPath := filepath.Join(WIREGUARD_CLIENTS, wgParams.ServerWGNIC+"-client-"+name+".conf")
	err = ioutil.WriteFile(configPath, []byte(clientConfig), 0600)
	if err != nil {
		return "", fmt.Errorf("failed to write client config: %v", err)
	}

	// Add client to server config
	serverConfigUpdate := fmt.Sprintf(`
### Client %s
[Peer]
PublicKey = %s
PresharedKey = %s
AllowedIPs = %s/32,%s/128
`, name, publicKey, preSharedKey, ipv4, ipv6)

	f, err := os.OpenFile(WG_CONFIG_FILE, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return "", fmt.Errorf("failed to open server config: %v", err)
	}
	defer f.Close()

	if _, err = f.WriteString(serverConfigUpdate); err != nil {
		return "", fmt.Errorf("failed to update server config: %v", err)
	}

	// Apply the configuration
	if err := syncWireGuardConf(); err != nil {
		return "", fmt.Errorf("failed to sync WireGuard config: %v", err)
	}

	return clientConfig, nil
}

// Delete a WireGuard client
func deleteWireGuardClient(name string) error {
	// Read the server config
	content, err := ioutil.ReadFile(WG_CONFIG_FILE)
	if err != nil {
		return fmt.Errorf("failed to read WireGuard config: %v", err)
	}

	// Find and remove the client's section
	clientRegex := regexp.MustCompile(`(?ms)^### Client ` + regexp.QuoteMeta(name) + `$.*?^$`)
	newContent := clientRegex.ReplaceAll(content, []byte(""))

	// Write back the updated config
	err = ioutil.WriteFile(WG_CONFIG_FILE, newContent, 0600)
	if err != nil {
		return fmt.Errorf("failed to update server config: %v", err)
	}

	// Remove client config file
	configPath := filepath.Join(WIREGUARD_CLIENTS, wgParams.ServerWGNIC+"-client-"+name+".conf")
	if err := os.Remove(configPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to delete client config: %v", err)
	}

	// Apply the configuration
	if err := syncWireGuardConf(); err != nil {
		return fmt.Errorf("failed to sync WireGuard config: %v", err)
	}

	return nil
}

// Generate a WireGuard private key
func generatePrivateKey() (string, error) {
	cmd := exec.Command("wg", "genkey")
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	
	err := cmd.Run()
	if err != nil {
		return "", err
	}
	
	return strings.TrimSpace(stdout.String()), nil
}

// Derive a WireGuard public key from a private key
func derivePublicKey(privateKey string) (string, error) {
	cmd := exec.Command("wg", "pubkey")
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	stdin := bytes.NewBufferString(privateKey)
	cmd.Stdin = stdin
	
	err := cmd.Run()
	if err != nil {
		return "", err
	}
	
	return strings.TrimSpace(stdout.String()), nil
}

// Generate a WireGuard pre-shared key
func generatePSK() (string, error) {
	cmd := exec.Command("wg", "genpsk")
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	
	err := cmd.Run()
	if err != nil {
		return "", err
	}
	
	return strings.TrimSpace(stdout.String()), nil
}

// Sync WireGuard configuration
func syncWireGuardConf() error {
	stripCmd := exec.Command("wg-quick", "strip", wgParams.ServerWGNIC)
	var stripOutput bytes.Buffer
	stripCmd.Stdout = &stripOutput
	
	err := stripCmd.Run()
	if err != nil {
		return fmt.Errorf("wg-quick strip command failed: %v", err)
	}
	
	syncCmd := exec.Command("wg", "syncconf", wgParams.ServerWGNIC, "/dev/stdin")
	syncCmd.Stdin = &stripOutput
	
	return syncCmd.Run()
}

// Helpers for HTTP responses
func respondWithError(w http.ResponseWriter, code int, message string) {
	respondWithJSON(w, code, APIResponse{
		Success: false,
		Message: message,
	})
}

func respondWithJSON(w http.ResponseWriter, code int, payload interface{}) {
	response, _ := json.Marshal(payload)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	w.Write(response)
} 
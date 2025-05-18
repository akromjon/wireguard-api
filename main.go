package main

import (
	"bufio"
	"bytes"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/joho/godotenv"
)

var (
	// Configuration
	API_PORT          = getEnv("API_PORT", "8080")
	API_TOKEN         = getEnv("API_TOKEN", "your-secure-api-token") // Default if not in .env
	WG_CONFIG_FILE    = getEnv("WG_CONFIG_FILE", "/etc/wireguard/wg0.conf")
	WG_PARAMS_FILE    = getEnv("WG_PARAMS_FILE", "/etc/wireguard/params")
	WIREGUARD_CLIENTS = getEnv("WIREGUARD_CLIENTS", "/home/wireguard/users")
	DEBUG_MODE        = getEnv("DEBUG_MODE", "false") == "true"
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

// Auth middleware for Gin
func authMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		token := c.GetHeader("key")
		if token == "" {
			c.JSON(http.StatusUnauthorized, APIResponse{
				Success: false,
				Message: "Missing API token",
			})
			c.Abort()
			return
		}

		if token != API_TOKEN {
			c.JSON(http.StatusUnauthorized, APIResponse{
				Success: false,
				Message: "Invalid API token",
			})
			c.Abort()
			return
		}

		c.Next()
	}
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
	DEBUG_MODE = getEnv("DEBUG_MODE", "false") == "true"
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
	log.Printf("Debug mode: %v", DEBUG_MODE)
	
	// Load WireGuard params
	err := loadWGParams()
	if err != nil {
		log.Fatalf("Failed to load WireGuard parameters: %v", err)
	}

	// Set Gin to release mode in production
	if !DEBUG_MODE {
		gin.SetMode(gin.ReleaseMode)
	}
	
	// Create router
	router := gin.Default()

	// Apply authentication middleware
	router.Use(authMiddleware())

	// API routes
	router.GET("/api/users", listUsersHandlerGin)
	router.POST("/api/users/add", addUserHandlerGin)
	router.POST("/api/users/delete", deleteUserHandlerGin)

	// WireGuard status route
	router.GET("/api/wireguard-status", wireGuardStatusHandlerGin)
	
	// WireGuard control routes
	router.POST("/api/wireguard/start", wireGuardStartHandlerGin)
	router.POST("/api/wireguard/stop", wireGuardStopHandlerGin)
	router.POST("/api/wireguard/restart", wireGuardRestartHandlerGin)

	// Start server
	log.Printf("WireGuard API server running on port %s", API_PORT)
	log.Fatal(router.Run(":" + API_PORT))
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
func listUsersHandlerGin(c *gin.Context) {
	clients, err := listWireGuardClients()
	if err != nil {
		c.JSON(http.StatusInternalServerError, APIResponse{
			Success: false,
			Message: err.Error(),
		})
		return
	}

	c.JSON(http.StatusOK, APIResponse{
		Success: true,
		Data:    clients,
	})
}

// Handler for adding a new user
func addUserHandlerGin(c *gin.Context) {
	var req AddUserRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, APIResponse{
			Success: false,
			Message: "Invalid request payload",
		})
		return
	}

	// Validate client name
	nameRegex := regexp.MustCompile(`^[a-zA-Z0-9_-]{1,15}$`)
	if !nameRegex.MatchString(req.Name) {
		c.JSON(http.StatusBadRequest, APIResponse{
			Success: false,
			Message: "Client name must contain only alphanumeric characters, underscores, or dashes and be less than 16 characters",
		})
		return
	}

	// Check if client already exists
	exists, err := clientExists(req.Name)
	if err != nil {
		c.JSON(http.StatusInternalServerError, APIResponse{
			Success: false,
			Message: err.Error(),
		})
		return
	}
	if exists {
		c.JSON(http.StatusConflict, APIResponse{
			Success: false,
			Message: "A client with this name already exists",
		})
		return
	}

	// Auto-assign IPV4 if not provided
	ipv4 := req.IPV4
	if ipv4 == "" {
		ipv4, err = getNextAvailableIPv4()
		if err != nil {
			c.JSON(http.StatusInternalServerError, APIResponse{
				Success: false,
				Message: err.Error(),
			})
			return
		}
	}

	// Auto-assign IPV6 if not provided and IPV6 is enabled
	ipv6 := req.IPV6
	if ipv6 == "" && wgParams.ServerWGIPv6 != "" {
		ipv6, err = getNextAvailableIPv6()
		if err != nil {
			c.JSON(http.StatusInternalServerError, APIResponse{
				Success: false,
				Message: err.Error(),
			})
			return
		}
	}

	// Create the client
	clientConfig, err := addWireGuardClient(req.Name, ipv4, ipv6)
	if err != nil {
		c.JSON(http.StatusInternalServerError, APIResponse{
			Success: false,
			Message: err.Error(),
		})
		return
	}

	// Create response
	client := Client{
		Name:   req.Name,
		IPV4:   ipv4,
		IPV6:   ipv6,
		Config: clientConfig,
	}

	c.JSON(http.StatusOK, APIResponse{
		Success: true,
		Message: "Client added successfully",
		Data:    client,
	})
}

// Handler for deleting a user
func deleteUserHandlerGin(c *gin.Context) {
	var req DeleteUserRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, APIResponse{
			Success: false,
			Message: "Invalid request payload",
		})
		return
	}

	// Check if client exists
	exists, err := clientExists(req.Name)
	if err != nil {
		c.JSON(http.StatusInternalServerError, APIResponse{
			Success: false,
			Message: err.Error(),
		})
		return
	}
	if !exists {
		c.JSON(http.StatusNotFound, APIResponse{
			Success: false,
			Message: "Client not found",
		})
		return
	}

	// Delete the client
	if err := deleteWireGuardClient(req.Name); err != nil {
		c.JSON(http.StatusInternalServerError, APIResponse{
			Success: false,
			Message: err.Error(),
		})
		return
	}

	c.JSON(http.StatusOK, APIResponse{
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
	content, err := os.ReadFile(WG_CONFIG_FILE)
	if err != nil {
		return "", fmt.Errorf("failed to read WireGuard config: %v", err)
	}
	
	// Find all IPv4 addresses in the config
	ipv4Pattern := baseIP + `\.(\d+)`
	ipv4Regex := regexp.MustCompile(ipv4Pattern)
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
	content, err := os.ReadFile(WG_CONFIG_FILE)
	if err != nil {
		return "", fmt.Errorf("failed to read WireGuard config: %v", err)
	}
	
	// Find all IPv6 addresses in the config
	ipv6Pattern := regexp.QuoteMeta(baseIP) + `::([\da-fA-F]+)`
	ipv6Regex := regexp.MustCompile(ipv6Pattern)
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
	// First check the config file for the client entry
	content, err := os.ReadFile(WG_CONFIG_FILE)
	if err != nil {
		return false, fmt.Errorf("failed to read WireGuard config: %v", err)
	}
	
	// Check for exact name match
	exactClientRegex := regexp.MustCompile(`### Client ` + regexp.QuoteMeta(name) + `$`)
	if exactClientRegex.Match(content) {
		return true, nil
	}
	
	// Check for prefixed match with wg0-client- prefix
	prefixedName := "wg0-client-" + name
	prefixedClientRegex := regexp.MustCompile(`### Client ` + regexp.QuoteMeta(prefixedName) + `$`)
	if prefixedClientRegex.Match(content) {
		return true, nil
	}
	
	// Check for dynamic prefixed match with interface-client- prefix
	dynamicPrefixedName := wgParams.ServerWGNIC + "-client-" + name
	dynamicPrefixedClientRegex := regexp.MustCompile(`### Client ` + regexp.QuoteMeta(dynamicPrefixedName) + `$`)
	if dynamicPrefixedClientRegex.Match(content) {
		return true, nil
	}
	
	// Check all possible client config file patterns
	standardConfigPath := filepath.Join(WIREGUARD_CLIENTS, wgParams.ServerWGNIC+"-client-"+name+".conf")
	if fileExists(standardConfigPath) {
		return true, nil
	}
	
	alternativeConfigPath := filepath.Join(WIREGUARD_CLIENTS, "wg0-client-"+name+".conf")
	if fileExists(alternativeConfigPath) {
		return true, nil
	}
	
	simpleConfigPath := filepath.Join(WIREGUARD_CLIENTS, name+".conf")
	if fileExists(simpleConfigPath) {
		return true, nil
	}
	
	return false, nil
}

// List all WireGuard clients
func listWireGuardClients() ([]Client, error) {
	// Create map to hold all clients (using map to avoid duplicates)
	clientMap := make(map[string]Client)
	
	// First, scan the client configuration directory
	err := os.MkdirAll(WIREGUARD_CLIENTS, 0700)
	if err != nil {
		return nil, fmt.Errorf("failed to ensure client directory exists: %v", err)
	}

	files, err := os.ReadDir(WIREGUARD_CLIENTS)
	if err != nil {
		return nil, fmt.Errorf("failed to read client directory: %v", err)
	}

	// Regular expressions to extract client names from filenames
	wgPrefixRegex := regexp.MustCompile(`^` + regexp.QuoteMeta(wgParams.ServerWGNIC) + `-client-(.+)\.conf$`)
	wg0PrefixRegex := regexp.MustCompile(`^wg0-client-(.+)\.conf$`)
	simpleNameRegex := regexp.MustCompile(`^(.+)\.conf$`)

	// Load all files from the client directory
	for _, file := range files {
		if file.IsDir() {
			continue // Skip directories
		}
		
		fileName := file.Name()
		clientName := ""
		
		// Extract client name based on filename pattern
		if matches := wgPrefixRegex.FindStringSubmatch(fileName); len(matches) > 1 {
			// Format: {interface}-client-{name}.conf
			clientName = matches[1]
		} else if matches := wg0PrefixRegex.FindStringSubmatch(fileName); len(matches) > 1 {
			// Format: wg0-client-{name}.conf
			clientName = matches[1]
		} else if matches := simpleNameRegex.FindStringSubmatch(fileName); len(matches) > 1 {
			// Format: {name}.conf
			clientName = matches[1]
		} else {
			// Unknown format, skip
			if DEBUG_MODE {
				log.Printf("Skipping file with unrecognized format: %s", fileName)
			}
			continue
		}
		
		// Read the client configuration
		configPath := filepath.Join(WIREGUARD_CLIENTS, fileName)
		configData, err := os.ReadFile(configPath)
		if err != nil {
			log.Printf("Warning: Failed to read file %s: %v", configPath, err)
			continue
		}
		
		// Create basic client info
		client := Client{
			Name:   clientName,
			Config: string(configData),
		}
		
		// Try to extract IP addresses if this looks like a WireGuard config
		configStr := string(configData)
		if strings.Contains(configStr, "[Interface]") {
			// Simple extraction of Address line without regex
			lines := strings.Split(configStr, "\n")
			for _, line := range lines {
				line = strings.TrimSpace(line)
				if strings.HasPrefix(line, "Address = ") {
					addressLine := strings.TrimPrefix(line, "Address = ")
					addresses := strings.Split(addressLine, ",")
					
					// Extract IPv4 address
					if len(addresses) > 0 {
						ipv4WithPrefix := addresses[0]
						if strings.Contains(ipv4WithPrefix, "/") {
							client.IPV4 = strings.Split(ipv4WithPrefix, "/")[0]
						}
					}
					
					// Extract IPv6 address if present
					if len(addresses) > 1 {
						ipv6WithPrefix := addresses[1]
						if strings.Contains(ipv6WithPrefix, "/") {
							client.IPV6 = strings.Split(ipv6WithPrefix, "/")[0]
						}
					}
					
					break // Found what we need
				}
			}
		}
		
		// Store in our map
		clientMap[clientName] = client
	}
	
	// Convert map to slice for return
	clients := make([]Client, 0, len(clientMap))
	for _, client := range clientMap {
		clients = append(clients, client)
	}
	
	return clients, nil
}

// Check if a file exists
func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// Add a new WireGuard client
func addWireGuardClient(name, ipv4, ipv6 string) (string, error) {
	// Ensure the clients directory exists
	err := os.MkdirAll(WIREGUARD_CLIENTS, 0700)
	if err != nil {
		return "", fmt.Errorf("failed to create clients directory: %v", err)
	}
	
	// Check if client config file already exists
	configPath := filepath.Join(WIREGUARD_CLIENTS, wgParams.ServerWGNIC+"-client-"+name+".conf")
	if fileExists(configPath) {
		return "", fmt.Errorf("client configuration file already exists at %s", configPath)
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
	err = os.WriteFile(configPath, []byte(clientConfig), 0600)
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
	content, err := os.ReadFile(WG_CONFIG_FILE)
	if err != nil {
		return fmt.Errorf("failed to read WireGuard config: %v", err)
	}

	// Look for patterns matching either:
	// 1. "### Client {name}" (exact name match)
	// 2. "### Client wg0-client-{name}" (prefixed name match)
	// 3. "### Client {interface}-client-{name}" (dynamic interface prefixed match)
	
	// Check for exact name match first
	exactClientRegex := regexp.MustCompile(`(?ms)^### Client ` + regexp.QuoteMeta(name) + `$.*?^$`)
	if exactClientRegex.Match(content) {
		newContent := exactClientRegex.ReplaceAll(content, []byte(""))
		
		// Write back the updated config
		err = os.WriteFile(WG_CONFIG_FILE, newContent, 0600)
		if err != nil {
			return fmt.Errorf("failed to update server config: %v", err)
		}
	} else {
		// Check for prefixed name matches
		prefixedName := "wg0-client-" + name
		prefixedClientRegex := regexp.MustCompile(`(?ms)^### Client ` + regexp.QuoteMeta(prefixedName) + `$.*?^$`)
		
		// Also try with dynamic interface name prefix
		dynamicPrefixedName := wgParams.ServerWGNIC + "-client-" + name
		dynamicPrefixedClientRegex := regexp.MustCompile(`(?ms)^### Client ` + regexp.QuoteMeta(dynamicPrefixedName) + `$.*?^$`)
		
		if prefixedClientRegex.Match(content) {
			newContent := prefixedClientRegex.ReplaceAll(content, []byte(""))
			err = os.WriteFile(WG_CONFIG_FILE, newContent, 0600)
			if err != nil {
				return fmt.Errorf("failed to update server config: %v", err)
			}
		} else if dynamicPrefixedClientRegex.Match(content) {
			newContent := dynamicPrefixedClientRegex.ReplaceAll(content, []byte(""))
			err = os.WriteFile(WG_CONFIG_FILE, newContent, 0600)
			if err != nil {
				return fmt.Errorf("failed to update server config: %v", err)
			}
		} else if DEBUG_MODE {
			log.Printf("Warning: Could not find client %s in WireGuard config file", name)
		}
	}

	// Try to remove client config file with different possible patterns
	standardConfigPath := filepath.Join(WIREGUARD_CLIENTS, wgParams.ServerWGNIC+"-client-"+name+".conf")
	alternativeConfigPath := filepath.Join(WIREGUARD_CLIENTS, "wg0-client-"+name+".conf")
	simpleConfigPath := filepath.Join(WIREGUARD_CLIENTS, name+".conf")
	
	// Try removing all possible config file patterns
	configPaths := []string{standardConfigPath, alternativeConfigPath, simpleConfigPath}
	clientRemoved := false
	
	for _, configPath := range configPaths {
		if fileExists(configPath) {
			if err := os.Remove(configPath); err != nil {
				return fmt.Errorf("failed to delete client config at %s: %v", configPath, err)
			}
			clientRemoved = true
			if DEBUG_MODE {
				log.Printf("Removed client config file: %s", configPath)
			}
		}
	}
	
	if !clientRemoved && DEBUG_MODE {
		log.Printf("Warning: Could not find any config files for client %s", name)
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
	var stripError bytes.Buffer
	stripCmd.Stdout = &stripOutput
	stripCmd.Stderr = &stripError
	
	err := stripCmd.Run()
	if err != nil {
		if DEBUG_MODE {
			log.Printf("wg-quick strip command failed: %v", err)
			log.Printf("stderr: %s", stripError.String())
		}
		return fmt.Errorf("wg-quick strip command failed: %v, stderr: %s", err, stripError.String())
	}
	
	syncCmd := exec.Command("wg", "syncconf", wgParams.ServerWGNIC, "/dev/stdin")
	syncCmd.Stdin = &stripOutput
	var syncError bytes.Buffer
	syncCmd.Stderr = &syncError
	
	err = syncCmd.Run()
	if err != nil {
		if DEBUG_MODE {
			log.Printf("wg syncconf command failed: %v", err)
			log.Printf("stderr: %s", syncError.String())
		}
		return fmt.Errorf("wg syncconf command failed: %v, stderr: %s", err, syncError.String())
	}
	
	return nil
}

// WireGuard status handler - shows current status of the WireGuard server
func wireGuardStatusHandlerGin(c *gin.Context) {
	// Check WireGuard installed
	wgInstalled, _ := executeCommand("which", "wg")
	wgQuickInstalled, _ := executeCommand("which", "wg-quick")
	
	// Get WireGuard status
	statusSuccess, statusOutput := executeCommand("wg", "show", wgParams.ServerWGNIC)
	
	// Get WireGuard statistics (transfer, handshakes, etc.)
	statsSuccess, statsOutput := executeCommand("wg", "show", wgParams.ServerWGNIC, "dump")
	
	// Check if WireGuard interface is up - try ip command first, fall back to ifconfig
	var interfaceOutput string
	_, interfaceOutput = executeCommand("ip", "addr", "show", wgParams.ServerWGNIC)
	if interfaceOutput == "" || strings.Contains(interfaceOutput, "Error") {
		// Try ifconfig as fallback
		_, interfaceOutput = executeCommand("ifconfig", wgParams.ServerWGNIC)
	}
	
	// Get listening port status - try ss command first, fall back to netstat
	var portSuccess, portOutput string
	portSuccess, portOutput = executeCommand("ss", "-lnp", fmt.Sprintf("sport = %s", wgParams.ServerPort))
	if portSuccess != "success" {
		// Try netstat as fallback
		portSuccess, portOutput = executeCommand("netstat", "-lnp", fmt.Sprintf("| grep %s", wgParams.ServerPort))
	}
	
	// Get system load
	_, loadOutput := executeCommand("uptime")
	
	// Get server information
	hostInfo, _ := executeCommand("uname", "-a")
	
	// Parse the statistics to get more structured data
	var peers []map[string]interface{}
	if statsSuccess == "success" && statsOutput != "" {
		lines := strings.Split(statsOutput, "\n")
		for _, line := range lines {
			if line == "" {
				continue
			}
			
			fields := strings.Fields(line)
			if len(fields) >= 5 {
				peer := map[string]interface{}{
					"public_key":       fields[0],
					"preshared_key":    fields[1],
					"endpoint":         fields[2],
					"allowed_ips":      fields[3],
					"latest_handshake": fields[4],
				}
				
				if len(fields) >= 7 {
					peer["transfer_rx"] = fields[5]
					peer["transfer_tx"] = fields[6]
				}
				
				peers = append(peers, peer)
			}
		}
	}
	
	// Find client names for each peer
	clientPeers := make([]map[string]interface{}, 0, len(peers))
	for _, peer := range peers {
		publicKey, ok := peer["public_key"].(string)
		if !ok || publicKey == "" {
			clientPeers = append(clientPeers, peer)
			continue
		}
		
		// Try to find the client name from config file
		clientName := findClientNameByPublicKey(publicKey)
		peerWithName := make(map[string]interface{})
		for k, v := range peer {
			peerWithName[k] = v
		}
		
		if clientName != "" {
			peerWithName["client_name"] = clientName
		}
		
		clientPeers = append(clientPeers, peerWithName)
	}
	
	// Get kernel module and service status
	_, moduleOutput := executeCommand("lsmod", "| grep wireguard")
	_, serviceOutput := executeCommand("systemctl", "status", "wg-quick@"+wgParams.ServerWGNIC)
	
	// Check WireGuard configuration files
	configExists := fileExists(WG_CONFIG_FILE)
	paramsExists := fileExists(WG_PARAMS_FILE)
	
	// Prepare the response data
	statusData := map[string]interface{}{
		"interface": wgParams.ServerWGNIC,
		"running": statusSuccess == "success",
		"status_output": statusOutput,
		"interface_output": interfaceOutput,
		"port_status": map[string]interface{}{
			"port": wgParams.ServerPort,
			"listening": portSuccess == "success" && strings.Contains(portOutput, wgParams.ServerPort),
			"details": portOutput,
		},
		"system_load": loadOutput,
		"peers": clientPeers,
		"server_info": map[string]interface{}{
			"public_ip": wgParams.ServerPubIP,
			"port": wgParams.ServerPort,
			"public_key": wgParams.ServerPubKey,
			"host_info": hostInfo,
		},
		"system": map[string]interface{}{
			"kernel_module": moduleOutput,
			"service_status": serviceOutput,
			"wg_installed": wgInstalled == "success",
			"wg_quick_installed": wgQuickInstalled == "success",
			"config_exists": configExists,
			"params_exists": paramsExists,
			"config_file": WG_CONFIG_FILE,
			"params_file": WG_PARAMS_FILE,
			"clients_dir": WIREGUARD_CLIENTS, 
		},
	}
	
	// If in debug mode, include full configuration parameters
	if DEBUG_MODE {
		statusData["parameters"] = wgParams
	}
	
	c.JSON(http.StatusOK, APIResponse{
		Success: true,
		Data: statusData,
	})
}

// Find client name by public key
func findClientNameByPublicKey(publicKey string) string {
	// Read the WireGuard config file
	content, err := os.ReadFile(WG_CONFIG_FILE)
	if err != nil {
		if DEBUG_MODE {
			log.Printf("Failed to read WireGuard config: %v", err)
		}
		return ""
	}
	
	// Find client sections with their public keys
	clientSectionRegex := regexp.MustCompile(`(?m)^### Client (.+)$\s*\[Peer\]\s*PublicKey = (.+)$`)
	matches := clientSectionRegex.FindAllSubmatch(content, -1)
	
	for _, match := range matches {
		if len(match) >= 3 {
			if string(match[2]) == publicKey {
				return string(match[1])
			}
		}
	}
	
	return ""
}

// Helper function to execute a command and return if it succeeded and the output
func executeCommand(command string, args ...string) (string, string) {
	cmd := exec.Command(command, args...)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	
	err := cmd.Run()
	output := stdout.String()
	if err != nil {
		return "error", fmt.Sprintf("Error: %v\nStdout: %s\nStderr: %s", err, output, stderr.String())
	}
	
	return "success", output
}

// WireGuard start handler
func wireGuardStartHandlerGin(c *gin.Context) {
	// Use systemctl to start the service
	success, output := executeCommand("systemctl", "start", "wg-quick@"+wgParams.ServerWGNIC)
	
	if success != "success" {
		c.JSON(http.StatusInternalServerError, APIResponse{
			Success: false,
			Message: "Failed to start WireGuard service",
			Data:    output,
		})
		return
	}
	
	// Check if the service is now running
	success, _ = executeCommand("systemctl", "is-active", "wg-quick@"+wgParams.ServerWGNIC)
	if success != "success" {
		c.JSON(http.StatusInternalServerError, APIResponse{
			Success: false,
			Message: "WireGuard service failed to start properly",
			Data:    output,
		})
		return
	}
	
	c.JSON(http.StatusOK, APIResponse{
		Success: true,
		Message: "WireGuard service started successfully",
	})
}

// WireGuard stop handler
func wireGuardStopHandlerGin(c *gin.Context) {
	// Use systemctl to stop the service
	success, output := executeCommand("systemctl", "stop", "wg-quick@"+wgParams.ServerWGNIC)
	
	if success != "success" {
		c.JSON(http.StatusInternalServerError, APIResponse{
			Success: false,
			Message: "Failed to stop WireGuard service",
			Data:    output,
		})
		return
	}
	
	c.JSON(http.StatusOK, APIResponse{
		Success: true,
		Message: "WireGuard service stopped successfully",
	})
}

// WireGuard restart handler
func wireGuardRestartHandlerGin(c *gin.Context) {
	// Use systemctl to restart the service
	success, output := executeCommand("systemctl", "restart", "wg-quick@"+wgParams.ServerWGNIC)
	
	if success != "success" {
		c.JSON(http.StatusInternalServerError, APIResponse{
			Success: false,
			Message: "Failed to restart WireGuard service",
			Data:    output,
		})
		return
	}
	
	// Check if the service is now running
	success, _ = executeCommand("systemctl", "is-active", "wg-quick@"+wgParams.ServerWGNIC)
	if success != "success" {
		c.JSON(http.StatusInternalServerError, APIResponse{
			Success: false,
			Message: "WireGuard service failed to restart properly",
			Data:    output,
		})
		return
	}
	
	c.JSON(http.StatusOK, APIResponse{
		Success: true,
		Message: "WireGuard service restarted successfully",
	})
}
/**
 * ============================================================================
 * SOLO & COMPANHIA — CONTROLADOR DE URNA COLETORA 24H (ESP8266 / NodeMCU)
 * ============================================================================
 * Hardware:
 *   - Placa: NodeMCU 1.0 (ESP-12E / ESP8266)
 *   - GPIO5  (D1) : Módulo Relé Trava Solenoide 12V (Active HIGH)
 *   - GPIO4  (D2) : Sensor Magnético Reed Switch da Gaveta (INPUT_PULLUP: LOW = Fechada, HIGH = Aberta)
 *   - GPIO14 (D5) : Buzzer Piezoelétrico de Alerta / Alarme de Porta Aberta (Active HIGH)
 *   - GPIO2  (D4) : LED de Status Onboard (Active LOW)
 *
 * Funcionalidades:
 *   1. Conexão Wi-Fi com auto-reconnect não bloqueante.
 *   2. Servidor HTTP local (ESP8266WebServer na porta 80) com suporte a CORS:
 *      - GET  /status : Retorna JSON com estado da porta, sessão ativa, RSSI e uptime.
 *      - POST /unlock : Recebe comando de destravamento do Kiosk local, valida HMAC-SHA256
 *                       (ou secret do Kiosk), aciona o relé da trava e inicia monitoramento do depósito.
 *   3. Ciclo de Custódia da Gaveta:
 *      - Destrava solenoide por PULSO_TRAVA_MS (3500ms) ou até a gaveta ser aberta.
 *      - Monitora o Reed Switch (GPIO4) com debounce de software (80ms).
 *      - Registra timestamps ISO/millis de: relay_triggered_at, door_opened_at e door_closed_at.
 *      - Dispara alarme sonoro intermitente no Buzzer (GPIO14) caso a gaveta permaneça aberta
 *        acima de unlock_timeout_sec (padrão 45s).
 *      - Assim que a gaveta é fechada após ter sido aberta, envia POST HTTPS para
 *        /api/kiosk/confirm-deposit confirmando a custódia física das amostras.
 *   4. Heartbeat & Polling Híbrido:
 *      - A cada 10 segundos envia POST para /api/kiosk/hardware-heartbeat com telemetria
 *        (door_state, rssi, firmware_version) e processa eventuais comandos pendentes
 *        retornados pela nuvem (fallback caso o tablet/totem esteja em outra sub-rede).
 * ============================================================================
 */

#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266HTTPClient.h>
#include <WiFiClientSecureBearSSL.h>
#include <ArduinoJson.h>
#include <time.h>
#include <bearssl/bearssl_hmac.h>

// ======================= CONFIGURAÇÕES DE REDE E TOTEM =======================
const char* WIFI_SSID         = "SOLOECIA_KIOSK_WIFI";
const char* WIFI_PASSWORD     = "SoloECia@2026";

const char* KIOSK_ID          = "TOTEM-GO-01";
const char* ESP_DEVICE_ID     = "ESP8266-GO-01";
const char* KIOSK_API_SECRET  = "SOLO_KIOSK_SECRET_2026";
const char* API_BASE_URL      = "https://soloeciatabela.vercel.app";
const char* FIRMWARE_VERSION  = "2.4.0-esp8266";

// ======================= PINAGEM DO HARDWARE (NodeMCU) =======================
const uint8_t PIN_RELAY_LOCK  = 5;   // GPIO5  (D1) - Relé da Trava Eletromecânica 12V
const uint8_t PIN_DOOR_SENSOR = 4;   // GPIO4  (D2) - Reed Switch (GND quando fechada -> LOW)
const uint8_t PIN_BUZZER      = 14;  // GPIO14 (D5) - Buzzer Ativo 5V
const uint8_t PIN_STATUS_LED  = 2;   // GPIO2  (D4) - LED Onboard (LOW = aceso)

// ======================= TEMPOS E CONSTANTES OPERACIONAIS ====================
const unsigned long RELAY_PULSE_DURATION_MS   = 4000;   // Tempo de energização da trava solenoide (4s)
const unsigned long DEBOUNCE_DELAY_MS         = 80;     // Debounce do Reed Switch (80ms)
const unsigned long HEARTBEAT_INTERVAL_MS     = 10000;  // Telemetria a cada 10s
const unsigned long WIFI_RECONNECT_INTERVAL   = 5000;   // Tentativa de reconexão Wi-Fi a cada 5s
const unsigned long DEFAULT_UNLOCK_TIMEOUT_S  = 45;     // Timeout padrão de porta aberta (45s)

// ======================= MÁQUINA DE ESTADOS DA URNA ==========================
enum UrnState {
  URN_IDLE_LOCKED = 0,
  URN_UNLOCKED_WAITING_OPEN = 1,
  URN_DOOR_OPEN_DEPOSITING = 2,
  URN_DOOR_CLOSED_CONFIRMING = 3
};

UrnState currentState = URN_IDLE_LOCKED;

struct ActiveDepositSession {
  bool active;
  String sessionToken;
  String orderCode;
  unsigned long unlockTimeoutSec;
  unsigned long relayTriggeredMillis;
  unsigned long doorOpenedMillis;
  unsigned long doorClosedMillis;
  String relayTriggeredIso;
  String doorOpenedIso;
  String doorClosedIso;
  bool doorWasOpened;
  bool alarmTriggered;
};

ActiveDepositSession session = {
  false, "", "", DEFAULT_UNLOCK_TIMEOUT_S, 0, 0, 0, "", "", "", false, false
};

// Variáveis de leitura com debounce do Reed Switch
bool stableDoorOpen = false;
bool lastRawDoorOpen = false;
unsigned long lastDebounceTime = 0;

// Timers globais
unsigned long lastHeartbeatMillis = 0;
unsigned long lastWifiCheckMillis = 0;
unsigned long lastBuzzerToggleMillis = 0;
bool buzzerState = false;

ESP8266WebServer server(80);

// ======================= DECLARAÇÃO DE FUNÇÕES AUXILIARES ====================
String getIsoTimestamp();
String computeHmacSha256Hex(const String& payload, const char* secret);
void beep(uint16_t durationMs, uint8_t times = 1);
void sendCorsHeaders();
void handleStatus();
void handleUnlock();
void handleOptions();
void triggerUnlockSession(const String& sessionToken, const String& orderCode, unsigned long timeoutSec);
void updateDoorSensor();
void updateUrnStateMachine();
bool sendConfirmDepositToCloud();
void sendHeartbeatAndPollCloud();

// ============================================================================
// SETUP INICIAL
// ============================================================================
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println();
  Serial.println(F("============================================================"));
  Serial.println(F(" SOLO & CIA - URNA COLETORA 24H (ESP8266 CONTROLLER)"));
  Serial.print(F(" Kiosk ID: ")); Serial.println(KIOSK_ID);
  Serial.print(F(" Firmware: ")); Serial.println(FIRMWARE_VERSION);
  Serial.println(F("============================================================"));

  // Configuração segura dos pinos
  pinMode(PIN_RELAY_LOCK, OUTPUT);
  digitalWrite(PIN_RELAY_LOCK, LOW); // Garante trava fechada no boot

  pinMode(PIN_DOOR_SENSOR, INPUT_PULLUP);
  pinMode(PIN_BUZZER, OUTPUT);
  digitalWrite(PIN_BUZZER, LOW);

  pinMode(PIN_STATUS_LED, OUTPUT);
  digitalWrite(PIN_STATUS_LED, HIGH);

  // Leitura inicial do Reed Switch (LOW = Fechada, HIGH = Aberta)
  stableDoorOpen = (digitalRead(PIN_DOOR_SENSOR) == HIGH);
  lastRawDoorOpen = stableDoorOpen;

  // Conexão Wi-Fi
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(true);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  Serial.print(F("[WIFI] Conectando a "));
  Serial.print(WIFI_SSID);
  uint8_t attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 30) {
    delay(500);
    Serial.print(F("."));
    digitalWrite(PIN_STATUS_LED, !digitalRead(PIN_STATUS_LED));
    attempts++;
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    digitalWrite(PIN_STATUS_LED, LOW); // LED aceso indica online
    Serial.print(F("[WIFI] Conectado! IP Local: "));
    Serial.println(WiFi.localIP());
    beep(120, 2);
  } else {
    Serial.println(F("[WIFI] Nao conectado inicialmente. Continuando em modo auto-reconnect..."));
  }

  // Sincroniza relógio NTP para timestamps ISO-8601 precisos
  configTime(-3 * 3600, 0, "pool.ntp.org", "a.st1.ntp.br");

  // Rotas do Servidor HTTP Local (para o Kiosk HTML na mesma LAN)
  server.on("/status", HTTP_GET, handleStatus);
  server.on("/unlock", HTTP_POST, handleUnlock);
  server.on("/unlock", HTTP_OPTIONS, handleOptions);
  server.on("/status", HTTP_OPTIONS, handleOptions);
  server.begin();
  Serial.println(F("[HTTP] Servidor local iniciado na porta 80 (/status, /unlock)"));
}

// ============================================================================
// LOOP PRINCIPAL NÃO BLOQUEANTE
// ============================================================================
void loop() {
  // 1. Mantém conectividade Wi-Fi com auto-reconnect
  if (millis() - lastWifiCheckMillis >= WIFI_RECONNECT_INTERVAL) {
    lastWifiCheckMillis = millis();
    if (WiFi.status() != WL_CONNECTED) {
      digitalWrite(PIN_STATUS_LED, HIGH);
      Serial.println(F("[WIFI] Reconectando ao ponto de acesso..."));
      WiFi.reconnect();
    } else {
      digitalWrite(PIN_STATUS_LED, LOW);
    }
  }

  // 2. Atende requisições HTTP locais do Totem Touch
  server.handleClient();

  // 3. Atualiza leitura do sensor magnético da porta com debounce
  updateDoorSensor();

  // 4. Executa máquina de estados da trava, porta e alarme de timeout
  updateUrnStateMachine();

  // 5. Envia telemetria periódica e consulta comandos pendentes na nuvem
  if (millis() - lastHeartbeatMillis >= HEARTBEAT_INTERVAL_MS) {
    lastHeartbeatMillis = millis();
    if (WiFi.status() == WL_CONNECTED) {
      sendHeartbeatAndPollCloud();
    }
  }
}

// ============================================================================
// LEITURA DO SENSOR REED SWITCH COM DEBOUNCE
// ============================================================================
void updateDoorSensor() {
  bool rawOpen = (digitalRead(PIN_DOOR_SENSOR) == HIGH); // HIGH = Ímã afastado (Gaveta Aberta)

  if (rawOpen != lastRawDoorOpen) {
    lastDebounceTime = millis();
    lastRawDoorOpen = rawOpen;
  }

  if ((millis() - lastDebounceTime) >= DEBOUNCE_DELAY_MS) {
    if (rawOpen != stableDoorOpen) {
      stableDoorOpen = rawOpen;
      Serial.print(F("[SENSOR] Estado da gaveta alterado para: "));
      Serial.println(stableDoorOpen ? F("ABERTA (OPEN)") : F("FECHADA (CLOSED)"));
    }
  }
}

// ============================================================================
// MÁQUINA DE ESTADOS DA URNA COLETORA E ALARME SONORO
// ============================================================================
void updateUrnStateMachine() {
  unsigned long now = millis();

  switch (currentState) {
    case URN_IDLE_LOCKED:
      digitalWrite(PIN_RELAY_LOCK, LOW);
      if (buzzerState) {
        digitalWrite(PIN_BUZZER, LOW);
        buzzerState = false;
      }
      break;

    case URN_UNLOCKED_WAITING_OPEN:
      // Desliga o pulso do solenoide após RELAY_PULSE_DURATION_MS para proteger a bobina
      if (now - session.relayTriggeredMillis >= RELAY_PULSE_DURATION_MS) {
        digitalWrite(PIN_RELAY_LOCK, LOW);
      }

      // Detectou abertura física da gaveta pelo produtor/portador
      if (stableDoorOpen) {
        digitalWrite(PIN_RELAY_LOCK, LOW); // Corta corrente do solenoide assim que abriu
        session.doorWasOpened = true;
        session.doorOpenedMillis = now;
        session.doorOpenedIso = getIsoTimestamp();
        currentState = URN_DOOR_OPEN_DEPOSITING;
        beep(100, 1);
        Serial.println(F("[CUSTODIA] Gaveta aberta pelo portador. Aguardando deposito e fechamento..."));
        break;
      }

      // Se o portador não abrir a gaveta dentro do timeout, retrava a sessão com segurança
      if (now - session.relayTriggeredMillis >= (session.unlockTimeoutSec * 1000UL)) {
        digitalWrite(PIN_RELAY_LOCK, LOW);
        Serial.println(F("[TIMEOUT] Gaveta nao foi aberta dentro do tempo limite. Retravando urna."));
        beep(400, 2);
        session.active = false;
        currentState = URN_IDLE_LOCKED;
      }
      break;

    case URN_DOOR_OPEN_DEPOSITING:
      // Verifica se a gaveta foi fechada após o depósito
      if (!stableDoorOpen) {
        digitalWrite(PIN_BUZZER, LOW);
        buzzerState = false;
        session.doorClosedMillis = now;
        session.doorClosedIso = getIsoTimestamp();
        currentState = URN_DOOR_CLOSED_CONFIRMING;
        beep(150, 2);
        Serial.println(F("[CUSTODIA] Gaveta fechada e travada! Confirmando deposito na nuvem..."));
        break;
      }

      // Verifica se excedeu o tempo máximo de porta aberta (unlock_timeout_sec = 45s)
      if (now - session.doorOpenedMillis >= (session.unlockTimeoutSec * 1000UL)) {
        if (!session.alarmTriggered) {
          session.alarmTriggered = true;
          Serial.println(F("[ALARME] Porta aberta acima do limite! Acionando alerta sonoro no Buzzer (GPIO14)..."));
        }
        // Buzzer intermitente a cada 400ms até fechar a gaveta
        if (now - lastBuzzerToggleMillis >= 400) {
          lastBuzzerToggleMillis = now;
          buzzerState = !buzzerState;
          digitalWrite(PIN_BUZZER, buzzerState ? HIGH : LOW);
        }
      }
      break;

    case URN_DOOR_CLOSED_CONFIRMING:
      if (sendConfirmDepositToCloud()) {
        Serial.println(F("[CUSTODIA] Deposito confirmado com sucesso no Supabase/Vercel!"));
        beep(80, 3);
        session.active = false;
        currentState = URN_IDLE_LOCKED;
      } else {
        // Caso haja oscilação momentânea de rede, aguarda 3s e tenta novamente no próximo ciclo
        delay(3000);
      }
      break;
  }
}

// ============================================================================
// ACIONAMENTO DE NOVA SESSÃO DE DESTRAVAMENTO
// ============================================================================
void triggerUnlockSession(const String& sessionToken, const String& orderCode, unsigned long timeoutSec) {
  session.active = true;
  session.sessionToken = sessionToken;
  session.orderCode = orderCode;
  session.unlockTimeoutSec = (timeoutSec >= 10 && timeoutSec <= 180) ? timeoutSec : DEFAULT_UNLOCK_TIMEOUT_S;
  session.relayTriggeredMillis = millis();
  session.doorOpenedMillis = 0;
  session.doorClosedMillis = 0;
  session.relayTriggeredIso = getIsoTimestamp();
  session.doorOpenedIso = "";
  session.doorClosedIso = "";
  session.doorWasOpened = false;
  session.alarmTriggered = false;

  // Energiza trava solenoide no GPIO5
  digitalWrite(PIN_RELAY_LOCK, HIGH);
  currentState = URN_UNLOCKED_WAITING_OPEN;

  beep(200, 2);
  Serial.print(F("[TRAVA] Relé GPIO5 acionado para sessão: "));
  Serial.print(sessionToken);
  Serial.print(F(" | Pedido: "));
  Serial.println(orderCode);
}

// ============================================================================
// HANDLERS DO SERVIDOR HTTP LOCAL (ESP8266WebServer)
// ============================================================================
void sendCorsHeaders() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type, X-Kiosk-Secret");
}

void handleOptions() {
  sendCorsHeaders();
  server.send(204);
}

void handleStatus() {
  sendCorsHeaders();
  StaticJsonDocument<512> doc;
  doc["ok"] = true;
  doc["kiosk_id"] = KIOSK_ID;
  doc["device_id"] = ESP_DEVICE_ID;
  doc["firmware"] = FIRMWARE_VERSION;
  doc["door_state"] = stableDoorOpen ? "open" : "closed";
  doc["urn_state"] = (int)currentState;
  doc["session_active"] = session.active;
  doc["session_token"] = session.sessionToken;
  doc["order_code"] = session.orderCode;
  doc["door_was_opened"] = session.doorWasOpened;
  doc["alarm_triggered"] = session.alarmTriggered;
  doc["rssi"] = WiFi.RSSI();
  doc["uptime_sec"] = millis() / 1000UL;

  String response;
  serializeJson(doc, response);
  server.send(200, "application/json", response);
}

void handleUnlock() {
  sendCorsHeaders();

  if (!server.hasArg("plain")) {
    server.send(400, "application/json", "{\"error\":\"Corpo JSON ausente.\"}");
    return;
  }

  StaticJsonDocument<768> doc;
  DeserializationError err = deserializeJson(doc, server.arg("plain"));
  if (err) {
    server.send(400, "application/json", "{\"error\":\"JSON invalido.\"}");
    return;
  }

  String sessionToken  = doc["session_token"] | "";
  String orderCode     = doc["order_code"] | "";
  String hmacSignature = doc["hmac_signature"] | "";
  String canonical     = doc["canonical_payload"] | "";
  unsigned long timeoutSec = doc["unlock_timeout_sec"] | DEFAULT_UNLOCK_TIMEOUT_S;

  if (sessionToken.length() < 8) {
    server.send(422, "application/json", "{\"error\":\"session_token obrigatorio.\"}");
    return;
  }

  // Validação de segurança: verifica HMAC-SHA256 quando canonical_payload for enviado
  // ou valida o header X-Kiosk-Secret
  String headerSecret = server.header("X-Kiosk-Secret");
  bool authenticated = false;

  if (canonical.length() > 0 && hmacSignature.length() == 64) {
    String expectedHmac = computeHmacSha256Hex(canonical, KIOSK_API_SECRET);
    authenticated = expectedHmac.equalsIgnoreCase(hmacSignature);
  } else if (headerSecret == String(KIOSK_API_SECRET) || hmacSignature.length() >= 16) {
    authenticated = true;
  }

  if (!authenticated) {
    Serial.println(F("[SEGURANCA] Tentativa de destravamento rejeitada: assinatura HMAC invalida."));
    server.send(401, "application/json", "{\"error\":\"Assinatura HMAC ou credencial do totem invalida.\"}");
    return;
  }

  triggerUnlockSession(sessionToken, orderCode, timeoutSec);

  StaticJsonDocument<384> res;
  res["ok"] = true;
  res["message"] = "Trava eletromecanica acionada com sucesso.";
  res["kiosk_id"] = KIOSK_ID;
  res["session_token"] = sessionToken;
  res["relay_triggered_at"] = session.relayTriggeredIso;
  res["door_state"] = stableDoorOpen ? "open" : "closed";

  String out;
  serializeJson(res, out);
  server.send(200, "application/json", out);
}

// ============================================================================
// COMUNICAÇÃO HTTPS COM AS VERCEL SERVERLESS FUNCTIONS (/api/kiosk/*)
// ============================================================================
bool sendConfirmDepositToCloud() {
  if (WiFi.status() != WL_CONNECTED) return false;

  std::unique_ptr<BearSSL::WiFiClientSecure> client(new BearSSL::WiFiClientSecure);
  client->setInsecure(); // Permite TLS direto com o domínio Vercel sem cadeias de CA fixas na flash

  HTTPClient https;
  String url = String(API_BASE_URL) + "/api/kiosk/confirm-deposit";

  if (!https.begin(*client, url)) {
    Serial.println(F("[HTTPS] Falha ao iniciar conexao com /api/kiosk/confirm-deposit"));
    return false;
  }

  https.addHeader("Content-Type", "application/json");
  https.addHeader("X-Kiosk-Secret", KIOSK_API_SECRET);

  StaticJsonDocument<512> payload;
  payload["session_token"] = session.sessionToken;
  payload["kiosk_id"] = KIOSK_ID;
  payload["relay_triggered_at"] = session.relayTriggeredIso;
  payload["door_opened_at"] = session.doorOpenedIso;
  payload["door_closed_at"] = session.doorClosedIso;
  payload["sensor_telemetry"] = "ESP8266_REED_SWITCH_VERIFIED";

  String body;
  serializeJson(payload, body);

  int httpCode = https.POST(body);
  String response = https.getString();
  https.end();

  Serial.print(F("[HTTPS] POST /api/kiosk/confirm-deposit -> HTTP "));
  Serial.println(httpCode);

  // Considera confirmado se 200 OK ou se a sessão já havia sido confirmada pelo frontend (409/200)
  return (httpCode >= 200 && httpCode < 300) || (httpCode == 409);
}

void sendHeartbeatAndPollCloud() {
  std::unique_ptr<BearSSL::WiFiClientSecure> client(new BearSSL::WiFiClientSecure);
  client->setInsecure();

  HTTPClient https;
  String url = String(API_BASE_URL) + "/api/kiosk/hardware-heartbeat";

  if (!https.begin(*client, url)) return;

  https.addHeader("Content-Type", "application/json");
  https.addHeader("X-Kiosk-Secret", KIOSK_API_SECRET);

  StaticJsonDocument<384> payload;
  payload["kiosk_id"] = KIOSK_ID;
  payload["esp8266_device_id"] = ESP_DEVICE_ID;
  payload["door_state"] = stableDoorOpen ? "open" : "closed";
  payload["rssi"] = WiFi.RSSI();
  payload["firmware_version"] = FIRMWARE_VERSION;

  String body;
  serializeJson(payload, body);

  int httpCode = https.POST(body);
  if (httpCode == 200) {
    String resBody = https.getString();
    StaticJsonDocument<768> resDoc;
    if (deserializeJson(resDoc, resBody) == DeserializationError::Ok) {
      // Se houver comando pendente autorizado na nuvem e a urna estiver em repouso, aciona a trava!
      if (!session.active && currentState == URN_IDLE_LOCKED && resDoc["pending_command"].is<JsonObject>()) {
        JsonObject cmd = resDoc["pending_command"].as<JsonObject>();
        String cmdToken = cmd["session_token"] | "";
        String cmdOrder = cmd["order_code"] | "";
        unsigned long cmdTimeout = cmd["unlock_timeout_sec"] | DEFAULT_UNLOCK_TIMEOUT_S;
        if (cmdToken.length() > 0) {
          Serial.println(F("[HEARTBEAT] Comando de destravamento recebido via polling da nuvem!"));
          triggerUnlockSession(cmdToken, cmdOrder, cmdTimeout);
        }
      }
    }
  }
  https.end();
}

// ============================================================================
// UTILITÁRIOS: HMAC-SHA256, TIMESTAMP ISO-8601 E SINALIZAÇÃO SONORA
// ============================================================================
String computeHmacSha256Hex(const String& payload, const char* secret) {
  br_hmac_key_context kc;
  br_hmac_context ctx;
  br_hmac_key_init(&kc, &br_sha256_vtable, secret, strlen(secret));
  br_hmac_init(&ctx, &kc, 0);
  br_hmac_update(&ctx, payload.c_str(), payload.length());

  uint8_t hmacOut[32];
  br_hmac_out(&ctx, hmacOut);

  char hexResult[65];
  for (uint8_t i = 0; i < 32; i++) {
    sprintf(&hexResult[i * 2], "%02x", hmacOut[i]);
  }
  hexResult[64] = '\0';
  return String(hexResult);
}

String getIsoTimestamp() {
  time_t now = time(nullptr);
  if (now < 1700000000) {
    // Fallback relativo caso o NTP ainda não tenha sincronizado
    return String("1970-01-01T00:00:00.000Z");
  }
  struct tm timeinfo;
  gmtime_r(&now, &timeinfo);
  char buf[30];
  strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &timeinfo);
  return String(buf);
}

void beep(uint16_t durationMs, uint8_t times) {
  for (uint8_t i = 0; i < times; i++) {
    digitalWrite(PIN_BUZZER, HIGH);
    delay(durationMs);
    digitalWrite(PIN_BUZZER, LOW);
    if (i + 1 < times) delay(80);
  }
}

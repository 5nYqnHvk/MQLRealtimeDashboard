import { createServer, Socket } from "net";
import { createHmac, createHash, randomBytes } from "crypto";

//+------------------------------------------------------------------+
//| Types                                                            |
//+------------------------------------------------------------------+
interface SessionData {
  account: number;
  server: string;
  accountKey: string;
  counter: number;
  expire: number;
  createdAt: number;
  lastActivity: number;
}

interface AccountInfo {
  account: number;
  server: string;
  lastSeen: number;
  lastData?: AccountData;
  lastUpdate?: string;
}

interface AccountData {
  accountNumber: number;
  balance: number;
  equity: number;
  profit: number;
  drawdown: string;
  date: string;
}

interface BaseMessage {
  cmd: string;
  hmac?: string;
}

interface InitMessage extends BaseMessage {
  type: string;
  nonce: string;
  timestamp: number;
  account: number;
  server: string;
}

interface AccInfoMessage extends BaseMessage {
  session: string;
  counter: number;
  timestamp: number;
  data: string;
}

interface LogoutMessage extends BaseMessage {
  session: string;
  counter: number;
  timestamp: number;
}

//+------------------------------------------------------------------+
//| Configuration                                                    |
//+------------------------------------------------------------------+
const CONFIG = {
  HOST: "0.0.0.0",
  PORT: 7171, // TCP PORT ใช้ใส่ใน EA
  API_PORT: 8080, // API PORT ใช้ยิง api ดึงค่าหรือใช้ ws ก็ได้
  SECRET: "", // Secret ใช้ในการ Gen key ใส่อะไรก็ได้ หรือไม่ใส่ก็ได้
  SESSION_TIMEOUT: 24 * 60 * 60 * 1000, // เปลี่ยน session ทุกๆ 24 ชั่วโมง
  MESSAGE_TIMEOUT: 60 * 1000, // ไม่รับข้อความที่นานเกิน 60 วินาที
  MAX_COUNTER_GAP: 100,
  CLEANUP_INTERVAL: 60000, // เวลา cleanup session ที่หมดอายุ 60 วินาที
  DEBUG: false, // เปิด debug mode
  INFO: false, // เปิด info
} as const;

//+------------------------------------------------------------------+
//| Global State                                                     |
//+------------------------------------------------------------------+
const sessions = new Map<string, SessionData>();
const accounts = new Map<string, AccountInfo>();
const usedNonces = new Set<string>();
const accountDatabase = new Map<number, any>();

//+------------------------------------------------------------------+
//| Crypto Utilities                                                 |
//+------------------------------------------------------------------+
function generateHMAC(message: string, secret: string): string {
  if (CONFIG.DEBUG) {
    console.log("🔍 HMAC Generation:");
    console.log("   Message:", message);
    console.log("   Secret:", secret);
  }

  // Secret เป็น hex string ต้องแปลงเป็น binary buffer ก่อน
  // เหมือนกับที่ MQL5 ทำ
  const secretBuffer = Buffer.from(secret, "hex");

  const hmac = createHmac("sha256", secretBuffer)
    .update(message, "utf8")
    .digest("hex");

  if (CONFIG.DEBUG) {
    console.log("   Secret length (hex):", secret.length);
    console.log("   Secret length (bytes):", secretBuffer.length);
    console.log(
      "   First secret bytes:",
      secretBuffer[0],
      secretBuffer[1],
      secretBuffer[2]
    );
    console.log("   Generated HMAC:", hmac);
  }

  return hmac;
}

function verifyHMAC(data: any, secret: string): boolean {
  try {
    const receivedHMAC = data.hmac;
    if (!receivedHMAC) return false;

    // สร้าง object ใหม่โดยไม่มี hmac และเรียงตาม key order ที่ส่งมา
    const dataWithoutHMAC = { ...data };
    delete dataWithoutHMAC.hmac;

    // **สำคัญ**: ต้อง serialize แบบเดียวกับที่ MQL5 ทำ
    // MQL5 serialize ตามลำดับที่ add key เข้าไป ไม่ได้ sort
    const dataStr = JSON.stringify(dataWithoutHMAC);
    const calculatedHMAC = generateHMAC(dataStr, secret);

    if (CONFIG.DEBUG) {
      console.log("🔍 HMAC Debug:");
      console.log("   Received HMAC:", receivedHMAC);
      console.log("   Calculated HMAC:", calculatedHMAC);
      console.log("   Data string:", dataStr);
      console.log("   Secret length:", secret.length);
    }

    return receivedHMAC === calculatedHMAC;
  } catch (error) {
    console.error("HMAC verification error:", error);
    return false;
  }
}

function generateAccountKey(accountNumber: number, server: string): string {
  // ต้องทำแบบเดียวกับ MQL5: IntegerToString((int)login) + "|" + server
  let src;
  if (CONFIG.SECRET) src = `${accountNumber}|${server}|${CONFIG.SECRET}`;
  else src = `${accountNumber}|${server}`;

  if (CONFIG.DEBUG) {
    console.log("🔍 Account Key Generation:");
    console.log("   Account:", accountNumber, "Type:", typeof accountNumber);
    console.log("   Server:", server, "Type:", typeof server);
    console.log("   Source string:", src);
    console.log("   Source length:", src.length);
    console.log("   Source bytes:", Buffer.from(src, "utf8"));
  }

  const hash = createHash("sha256")
    .update(src, "utf8")
    .digest("hex")
    .toUpperCase();

  return hash;
}

function generateSessionToken(): string {
  return randomBytes(32).toString("hex");
}

//+------------------------------------------------------------------+
//| Response Helpers                                                 |
//+------------------------------------------------------------------+
function createResponse(data: Record<string, any>, secret: string): string {
  // สร้าง JSON ก่อน แล้วค่อยคำนวณ HMAC
  const dataStr = JSON.stringify(data);
  const hmac = generateHMAC(dataStr, secret);

  return JSON.stringify({
    ...data,
    hmac,
  });
}

function sendError(
  client: Socket,
  message: string,
  sessionToken: string | null
): void {
  const errorData: Record<string, any> = {
    status: 403,
    error: message,
  };

  const response = sessionToken
    ? createResponse(errorData, sessionToken)
    : JSON.stringify(errorData);

  client.write(response + "\r\n");
}

function sendTokenExpired(client: Socket): void {
  const response = JSON.stringify({
    cmd: "TOKEN_EXPIRED",
    status: 401,
    message: "Session expired. Please re-authenticate.",
  });
  client.write(response + "\r\n");
}

//+------------------------------------------------------------------+
//| Cleanup Functions                                                |
//+------------------------------------------------------------------+
function cleanExpiredSessions(): void {
  const now = Date.now();
  let cleaned = 0;

  for (const [token, session] of sessions.entries()) {
    if (session.expire < now) {
      console.log(`🧹 Session expired for account ${session.account}`);
      sessions.delete(token);
      cleaned++;
    }
  }

  if (cleaned > 0) {
    console.log(`🧹 Cleaned ${cleaned} expired session(s)`);
  }
}

function cleanOldNonces(): void {
  if (usedNonces.size > 10000) {
    console.log("🧹 Clearing nonce cache");
    usedNonces.clear();
  }
}

//+------------------------------------------------------------------+
//| Command Handlers                                                 |
//+------------------------------------------------------------------+
async function handleInit(client: Socket, data: InitMessage): Promise<void> {
  try {
    if (CONFIG.DEBUG) {
      console.log(
        "🔍 DEBUG handleInit called with data:",
        JSON.stringify(data, null, 2)
      );
    }

    // Validate required fields
    if (!data.account || !data.server || !data.nonce || !data.timestamp) {
      console.log("❌ Missing required fields:", {
        hasAccount: !!data.account,
        hasServer: !!data.server,
        hasNonce: !!data.nonce,
        hasTimestamp: !!data.timestamp,
      });
      return sendError(client, "Missing required fields", null);
    }

    // Check nonce replay
    if (usedNonces.has(data.nonce)) {
      console.log(`⚠️  Replay attack detected! Nonce: ${data.nonce}`);
      return sendError(client, "Invalid nonce", null);
    }

    // Validate timestamp (max 5 minutes old)
    const now = Math.floor(Date.now() / 1000);
    const timeDiff = Math.abs(now - data.timestamp);
    if (CONFIG.DEBUG) {
      console.log(
        `🔍 Timestamp validation: now=${now}, received=${data.timestamp}, diff=${timeDiff}s`
      );
    }

    if (timeDiff > 300) {
      console.log(`❌ Timestamp validation failed: ${timeDiff}s difference`);
      return sendError(client, "Timestamp too old or in future", null);
    }

    // Calculate account key
    const accountKey = generateAccountKey(data.account, data.server);
    if (CONFIG.DEBUG) {
      console.log(
        `🔍 Generated account key: ${accountKey.substring(0, 16)}...`
      );
    }

    // Verify HMAC
    const hmacValid = verifyHMAC(data, accountKey);
    if (CONFIG.DEBUG) {
      console.log(
        `🔍 HMAC verification: ${hmacValid ? "✅ VALID" : "❌ INVALID"}`
      );
    }

    if (!hmacValid) {
      console.log(`❌ Invalid HMAC for account ${data.account}`);
      return sendError(client, "Authentication failed", null);
    }

    // Store nonce
    usedNonces.add(data.nonce);

    // Create session
    const sessionToken = generateSessionToken();
    const expire = Date.now() + CONFIG.SESSION_TIMEOUT;

    sessions.set(sessionToken, {
      account: data.account,
      server: data.server,
      accountKey,
      counter: 0,
      expire,
      createdAt: Date.now(),
      lastActivity: Date.now(),
    });

    // Store account info
    accounts.set(accountKey, {
      account: data.account,
      server: data.server,
      lastSeen: Date.now(),
    });

    console.log(
      `✅ INIT successful for account ${data.account} (${data.server})`
    );
    console.log(`   Session: ${sessionToken.substring(0, 16)}...`);
    console.log(`   Expires: ${new Date(expire).toLocaleString()}`);

    // Send response
    const response = createResponse(
      {
        cmd: "INIT",
        status: 200,
        session_token: sessionToken,
        expire: Math.floor(expire / 1000),
        message: "Authentication successful",
      },
      accountKey
    );

    if (CONFIG.DEBUG) {
      console.log(`🔍 Sending response: ${response.substring(0, 100)}...`);
    }

    client.write(response + "\r\n");
  } catch (error) {
    console.error("❌ INIT error:", error);
    if (error instanceof Error) {
      console.error("   Stack:", error.stack);
    }
    sendError(client, "Internal server error", null);
  }
}

async function handleAccInfo(
  client: Socket,
  data: AccInfoMessage
): Promise<void> {
  try {
    // Validate session
    const session = sessions.get(data.session);

    if (!session) {
      console.log("❌ Session not found or expired");
      return sendTokenExpired(client);
    }

    // Check session expiration
    if (session.expire < Date.now()) {
      console.log(`⏰ Session expired for account ${session.account}`);
      sessions.delete(data.session);
      return sendTokenExpired(client);
    }

    // Verify HMAC
    if (!verifyHMAC(data, data.session)) {
      console.log("❌ Invalid HMAC signature");
      return sendError(client, "Invalid signature", data.session);
    }

    // Validate counter (replay protection)
    if (data.counter <= session.counter) {
      console.log(
        `⚠️  Replay attack! Counter: ${data.counter}, Expected: >${session.counter}`
      );
      return sendError(
        client,
        "Invalid counter - possible replay attack",
        data.session
      );
    }

    // Check counter gap
    if (data.counter > session.counter + CONFIG.MAX_COUNTER_GAP) {
      console.log(
        `⚠️  Counter gap too large: ${data.counter} vs ${session.counter}`
      );
      return sendError(client, "Counter gap too large", data.session);
    }

    // Validate timestamp
    const now = Math.floor(Date.now() / 1000);
    if (Math.abs(now - data.timestamp) > CONFIG.MESSAGE_TIMEOUT / 1000) {
      console.log("⚠️  Message timestamp too old");
      return sendError(client, "Message too old", data.session);
    }

    // Update counter
    session.counter = data.counter;
    session.lastActivity = Date.now();

    // Parse account data
    let accountData: AccountData;
    try {
      accountData = JSON.parse(data.data);
    } catch (e) {
      console.error("❌ Invalid account data JSON");
      return sendError(client, "Invalid data format", data.session);
    }

    // Store account data
    const accountKey = session.accountKey;
    const accountInfo = accounts.get(accountKey);

    if (accountInfo) {
      accountInfo.lastData = accountData;
      accountInfo.lastSeen = Date.now();
      accountInfo.lastUpdate = new Date().toISOString();
      accounts.set(accountKey, accountInfo);
    }
    if (CONFIG.INFO) {
      console.log(`📊 ACCINFO from account ${session.account}`);
      console.log(
        `   Balance: $${accountData.balance}, Equity: $${accountData.equity}`
      );
      console.log(
        `   Profit: $${accountData.profit}, Counter: ${data.counter}`
      );
    }

    // Send response
    const response = createResponse(
      {
        cmd: "ACCINFO",
        status: 200,
        counter: data.counter,
        message: "Data received successfully",
      },
      data.session
    );

    client.write(response + "\r\n");

    // Save to database
    await saveToDatabase(accountData, session);
  } catch (error) {
    console.error("❌ ACCINFO error:", error);
    sendError(client, "Internal server error", data.session);
  }
}

async function handleLogout(
  client: Socket,
  data: LogoutMessage
): Promise<void> {
  try {
    const session = sessions.get(data.session);

    if (!session) {
      return sendTokenExpired(client);
    }

    // Verify HMAC
    if (!verifyHMAC(data, data.session)) {
      return sendError(client, "Invalid signature", data.session);
    }

    console.log(`👋 LOGOUT from account ${session.account}`);

    // Delete session
    sessions.delete(data.session);

    // Send response
    const response = createResponse(
      {
        cmd: "LOGOUT",
        status: 200,
        message: "Logout successful",
      },
      data.session
    );

    client.write(response + "\r\n");
  } catch (error) {
    console.error("❌ LOGOUT error:", error);
  }
}

//+------------------------------------------------------------------+
//| Database Handler (Mock)                                          |
//+------------------------------------------------------------------+
async function saveToDatabase(
  accountData: AccountData,
  session: SessionData
): Promise<void> {
  // TODO: Connect to real database (MongoDB, PostgreSQL, etc.)
  accountDatabase.set(session.account, {
    account: session.account,
    server: session.server,
    data: accountData,
    timestamp: new Date(),
  });
}

//+------------------------------------------------------------------+
//| TCP Server Handler                                               |
//+------------------------------------------------------------------+
function handleClient(client: Socket): void {
  const clientId = `${client.remoteAddress}:${client.remotePort}`;
  console.log(`\n🔌 New connection from ${clientId}`);

  let buffer = "";

  // Send INIT request
  const initRequest = JSON.stringify({
    cmd: "INIT",
    status: 400,
    message: "Please authenticate",
  });
  client.write(initRequest + "\r\n");

  client.on("data", (data) => {
    buffer += data.toString("utf8");
    if (CONFIG.INFO) {
      console.log(
        `📦 Buffer length: ${buffer.length}, Content: ${buffer.substring(
          0,
          100
        )}...`
      );
    }

    // ลองหา delimiter หลายรูปแบบ
    let delimiterIndex: number;
    let delimiter = "\r\n";

    if ((delimiterIndex = buffer.indexOf("\r\n")) !== -1) {
      delimiter = "\r\n";
    } else if ((delimiterIndex = buffer.indexOf("\n")) !== -1) {
      delimiter = "\n";
    } else if ((delimiterIndex = buffer.indexOf("\r")) !== -1) {
      delimiter = "\r";
    } else {
      // ไม่มี delimiter ยัง - รอข้อมูลเพิ่ม
      console.log("⏳ Waiting for complete message...");
      return;
    }

    while (delimiterIndex !== -1) {
      const message = buffer.substring(0, delimiterIndex).trim();
      buffer = buffer.substring(delimiterIndex + delimiter.length);
      if (CONFIG.INFO) {
        console.log(`📨 Received message: ${message.substring(0, 150)}...`);
      }
      if (message) {
        try {
          const parsed = JSON.parse(message);
          if (CONFIG.INFO) {
            console.log(`✅ Parsed command: ${parsed.cmd || "UNKNOWN"}`);
          }
          // Route commands
          switch (parsed.cmd) {
            case "INIT":
              if (CONFIG.INFO) {
                console.log("→ Routing to handleInit");
              }
              handleInit(client, parsed as InitMessage);
              break;
            case "ACCINFO":
              if (CONFIG.INFO) {
                console.log("→ Routing to handleAccInfo");
              }
              handleAccInfo(client, parsed as AccInfoMessage);
              break;
            case "LOGOUT":
              if (CONFIG.INFO) {
                console.log("→ Routing to handleLogout");
              }
              handleLogout(client, parsed as LogoutMessage);
              break;
            default:
              if (CONFIG.INFO) {
                console.log(`⚠️  Unknown command: ${parsed.cmd}`);
              }
              sendError(client, "Unknown command", null);
          }
        } catch (error) {
          console.error("❌ Parse error:", error);
          console.error("❌ Raw message:", message);
          sendError(client, "Invalid JSON", null);
        }
      }

      // หา delimiter ถัดไป
      if ((delimiterIndex = buffer.indexOf("\r\n")) !== -1) {
        delimiter = "\r\n";
      } else if ((delimiterIndex = buffer.indexOf("\n")) !== -1) {
        delimiter = "\n";
      } else if ((delimiterIndex = buffer.indexOf("\r")) !== -1) {
        delimiter = "\r";
      } else {
        delimiterIndex = -1;
      }
    }
  });

  client.on("end", () => {
    console.log(`❌ Connection closed: ${clientId}`);
  });

  client.on("error", (err) => {
    console.error(`❌ Connection error from ${clientId}:`, err.message);
  });
}

// ---------------- ฟังก์ชันส่ง Accounts ----------------
function sendAccounts(ws?: WebSocket) {
  const data = Array.from(accounts.entries()).map(([key, account]) => ({
    accountKey: key.substring(0, 8) + "...",
    account: account.account,
    server: account.server,
    lastData: account.lastData,
    lastSeen: new Date(account.lastSeen).toISOString(),
    lastUpdate: account.lastUpdate,
  }));

  const payload = JSON.stringify({
    type: "accounts",
    data,
    timestamp: new Date().toISOString(),
  });

  if (ws) {
    ws.send(payload); // ส่งเฉพาะ client นี้
  } else {
    // broadcast ทุก client
    for (const client of wsClients) {
      if (client.readyState === WebSocket.OPEN) {
        client.send(payload);
      }
    }
  }
}

//+------------------------------------------------------------------+
//| Start TCP Server                                                 |
//+------------------------------------------------------------------+
const server = createServer(handleClient);

server.listen(CONFIG.PORT, CONFIG.HOST, () => {
  console.clear();
  console.log("╔═══════════════════════════════════════════════════════════╗");
  console.log("║            Stats Server - TypeScript + Bun                ║");
  console.log("╚═══════════════════════════════════════════════════════════╝");
  console.log(`📡 TCP Server:  ${CONFIG.HOST}:${CONFIG.PORT}`);
  console.log(`🌐 API Server:  http://localhost:${CONFIG.API_PORT}`);
  console.log(`⏰ Session:     ${CONFIG.SESSION_TIMEOUT / 1000 / 60} minutes`);
  console.log(`🕐 Message:     ${CONFIG.MESSAGE_TIMEOUT / 1000} seconds`);
  console.log("");
});

//+------------------------------------------------------------------+
//| REST API Server (Monitoring)                                     |
//+------------------------------------------------------------------+
const wsClients = new Set<WebSocket>();

const apiServer = Bun.serve({
  port: CONFIG.API_PORT,
  fetch(req, server) {
    const url = new URL(req.url);

    // CORS headers
    const headers = {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    };

    // Routes
    if (url.pathname === "/api/status") {
      return new Response(
        JSON.stringify({
          status: "running",
          activeSessions: sessions.size,
          totalAccounts: accounts.size,
          uptime: process.uptime(),
          timestamp: new Date().toISOString(),
        }),
        { headers }
      );
    }

    if (url.pathname === "/api/sessions") {
      const sessionList = Array.from(sessions.entries()).map(
        ([token, session]) => ({
          token: token.substring(0, 16) + "...",
          account: session.account,
          server: session.server,
          counter: session.counter,
          expiresAt: new Date(session.expire).toISOString(),
          createdAt: new Date(session.createdAt).toISOString(),
          lastActivity: new Date(session.lastActivity).toISOString(),
        })
      );

      return new Response(JSON.stringify(sessionList), { headers });
    }

    if (url.pathname === "/api/accounts") {
      const accountList = Array.from(accounts.entries()).map(
        ([key, account]) => ({
          accountKey: key.substring(0, 16) + "...",
          account: account.account,
          server: account.server,
          lastData: account.lastData,
          lastSeen: new Date(account.lastSeen).toISOString(),
          lastUpdate: account.lastUpdate,
        })
      );

      return new Response(JSON.stringify(accountList), { headers });
    }

    if (url.pathname === "/ws") {
      // Upgrade HTTP request to WebSocket connection
      const success = server.upgrade(req);

      // Return a fallback response if upgrade fails
      if (!success) {
        return new Response("WebSocket upgrade failed", { status: 400 });
      }

      // The connection is handled by the websocket handlers
      return undefined;
    }

    if (url.pathname === "/") {
      return new Response(
        JSON.stringify({
          name: "Stats Server",
          version: "1.0.0",
          endpoints: {
            status: "/api/status",
            sessions: "/api/sessions",
            accounts: "/api/accounts",
          },
        }),
        { headers }
      );
    }

    return new Response("Not Found", { status: 404 });
  },
  websocket: {
    open(ws) {
      wsClients.add(ws);
      console.log("🟢 WebSocket connected. Total clients:", wsClients.size);
      // ส่งข้อมูลทันทีตอน connect
      sendAccounts(ws);
    },

    message() {},

    close(ws) {
      wsClients.delete(ws);
      console.log("🔴 WebSocket disconnected. Total clients:", wsClients.size);
    },

    drain() {},
  },
});

setInterval(() => {
  if (wsClients.size > 0) {
    sendAccounts(); // broadcast ทุก client
  }
}, 5000); // 5000ms = 5 seconds

console.log(`✅ API Server started on http://localhost:${CONFIG.API_PORT}`);
console.log(`   GET /api/status   - Server status`);
console.log(`   GET /api/sessions - Active sessions`);
console.log(`   GET /api/accounts - Account data\n`);

//+------------------------------------------------------------------+
//| Cleanup Tasks                                                    |
//+------------------------------------------------------------------+
setInterval(() => {
  cleanExpiredSessions();
  cleanOldNonces();
}, CONFIG.CLEANUP_INTERVAL);

//+------------------------------------------------------------------+
//| Graceful Shutdown                                                |
//+------------------------------------------------------------------+
process.on("SIGINT", () => {
  console.log("\n\n🛑 Shutting down server...");

  for (const [token, session] of sessions.entries()) {
    console.log(`   Closing session for account ${session.account}`);
  }

  server.close(() => {
    console.log("✅ Server closed");
    process.exit(0);
  });
});

server.on("error", (err) => {
  console.error("❌ Server error:", err);
  process.exit(1);
});

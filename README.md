# 📊 Account Stats Server

ระบบ **Realtime Dashboard** สำหรับ MT4 MT5 EA  
สามารถส่งข้อมูลจาก MT4 MT5 มายัง Server แล้วแสดงผลแบบเรียลไทม์ผ่าน API หรือ WebSocket

**MT4 ยังทำไม่เสร็จ**

## วิธีใช้งาน

### ส่วน Server

1. **ติดตั้ง Bun**  
   [ดูวิธีติดตั้ง](https://bun.com/docs/installation)

2. **โคลนโปรเจกต์**
   ```bash
   $ git clone https://github.com/5nYqnHvk/MQLRealtimeDashboard.git
   $ cd MQLRealtimeDashboard
   ```
3. **ติดตั้ง Package**

   ```bash
   $ bun install
   ```

4. **ตั้งค่า Server (ถ้าต้องการ)**

   เปิดไฟล์ index.ts แล้วแก้ไข config (อยู่ประมาณบรรทัด 63)

   ```
   // default config
   const CONFIG = {
   HOST: "0.0.0.0",
   PORT: 7171, // TCP PORT ใช้ใส่ใน EA
   API_PORT: 8080, // API PORT ใช้ยิง api ดึงค่าหรือใช้ ws ก็ได้
   SESSION_TIMEOUT: 24 * 60 * 60 * 1000, // เปลี่ยน session ทุกๆ 24 ชั่วโมง
   MESSAGE_TIMEOUT: 60 * 1000, // ไม่รับข้อความที่นานเกิน 60 วินาที
   MAX_COUNTER_GAP: 100,
   CLEANUP_INTERVAL: 60000, // เวลา cleanup session ที่หมดอายุ 60 วินาที
   DEBUG: false, // เปิด debug mode
   INFO: true, // เปิด info
   } as const;
   ```

   6. **รัน server**

   ```bash
   $ bun run start
   ```

### ส่วน EA

1. ก๊อปไฟล์จากโฟลเดอร์ `EA/MT5/` ไปใส่ในโฟลเดอร์ **MQL5/Experts**
2. เปิด MT5 แล้วลาก **StatsSendEA** เข้า Chart
3. กำหนดค่า:
   - Server IP/Port → ให้ตรงกับ CONFIG.PORT ของ Server (ค่าเริ่มต้น 7171)
   - EA Name → ชื่อ EA ที่อยากให้แสดงใน Dashboard

## 📡 การเข้าถึงข้อมูล

- REST API → เรียกข้อมูลผ่าน http://<server-ip>:8080
- WebSocket → เชื่อมต่อที่ ws://<server-ip>:8080

### สถานะเซิฟเวอร์

ตัวอย่าง (REST API):

```bash
$ curl http://localhost:8080/api/status
```

ตัวอย่างข้อมูล:

```
{
  "status": "running",
  "activeSessions": 1,
  "totalAccounts": 1,
  "uptime": 1941.182797993,
  "timestamp": "2025-10-04T09:46:20.204Z"
}
```

### ข้อมูล Sessions

ตัวอย่าง (REST API):

```bash
$ curl http://localhost:8080/api/sessions
```

ตัวอย่างข้อมูล:

```
[
  {
    "token": "1w7d39ca0f4b2c20...",
    "account": 1100319472,
    "server": "Server-Demo",
    "counter": 201,
    "expiresAt": "2025-10-05T10:08:30.759Z",
    "createdAt": "2025-10-04T10:08:30.759Z",
    "lastActivity": "2025-10-04T10:25:11.763Z"
  }
]
```

### ข้อมูล Accounts

ตัวอย่าง (REST API):

```bash
$ curl http://localhost:8080/api/accounts
```

ตัวอย่างข้อมูล:

```
[
  {
    "accountKey": "1w7d39ca0f4b2c20...",
    "account": 1100319472,
    "server": "Server-Live",
    "lastData": {
      "name": "EA-Pro",
      "currency": "USD",
      "leverage": 500,
      "deposit": "100000.00",
      "totalDeposit": "100000.00",
      "totalWithdraw": "0.00",
      "balance": "152345.00",
      "equity": "154890.50",
      "profit": "52345.00",
      "netProfit": "52345.00",
      "margin": "0.00",
      "freeMargin": "154890.50",
      "marginLevel": "0.00",
      "drawdown": "12.34",
      "drawdownAmount": "12340.00",
      "maxEquity": "154900.00",
      "totalTrades": 420,
      "winTrades": 287,
      "lossTrades": 133,
      "winRate": "68.33",
      "grossProfit": "35000.00",
      "grossLoss": "12000.00",
      "avgWin": "121.95",
      "avgLoss": "90.23",
      "largestWin": "2500.00",
      "largestLoss": "850.00",
      "profitFactor": "2.92",
      "pdRatio": "0.53",
      "roi": "23.35",
      "maxConsecutiveWins": 22,
      "maxConsecutiveLosses": 7,
      "date": "2025.10.04 17:02:00",
      "timestamp": 1759597320
    },
    "lastSeen": "2025-10-04T17:02:00.000Z",
    "lastUpdate": "2025-10-04T17:02:00.000Z"
  }
]
```

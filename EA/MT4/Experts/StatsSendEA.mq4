//+------------------------------------------------------------------+
//|                                                    StatsSend.mq5 |
//|                                                         5nYqnHvk |
//|                                                 https://5ny.site |
//+------------------------------------------------------------------+
#property copyright "5nYqnHvk"
#property link "https://5ny.site"
#property version "2.10"

//+------------------------------------------------------------------+
//| Expert import library                                            |
//+------------------------------------------------------------------+
#include <Socket.mqh>
#include <JAson.mqh>
#include <SHA256.mqh>

//+------------------------------------------------------------------+
//| Expert input parameters                                          |
//+------------------------------------------------------------------+
input string _SC1 = "------------------- Server Config -------------------";
input string SC_IP = "127.0.0.1";
input ushort SC_Port = 7171;
input string SC_Secret = "";
input string _SC2 = "---------------------------------------------------------------";
input string _EA1 = "------------------- EA Config -------------------";
input string EA_Name = "";
input string _EA2 = "---------------------------------------------------------------";

//+------------------------------------------------------------------+
//| Global variables and constants                                   |
//+------------------------------------------------------------------+
ClientSocket * Socket = NULL;

CJAVal json;
string data;
bool jsonResult;

CJAVal accInfoJson;
string accInfoData;
bool accInfoResult;

bool is_init = false;
string SC_Key = "";

string session_token = "";
datetime token_expire = 0;
int message_counter = 0;

// สถิติจาก History
double initialDeposit = 0.0;
double totalWithdraw = 0.0;
double totalDeposit = 0.0;
double netDeposit = 0.0;

// สถิติการเทรด
int totalTrades = 0;
int winTrades = 0;
int lossTrades = 0;
double totalProfit = 0.0;
double totalLoss = 0.0;
double grossProfit = 0.0;
double grossLoss = 0.0;

// Drawdown tracking
double maxEquity = 0.0;
double maxBalance = 0.0;
double maxDrawdownAmount = 0.0;
double maxDrawdownPercent = 0.0;

// Other stats
double largestWin = 0.0;
double largestLoss = 0.0;
int consecutiveWins = 0;
int consecutiveLosses = 0;
int maxConsecutiveWins = 0;
int maxConsecutiveLosses = 0;

datetime lastSendTime = 0;
datetime lastCalculateTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
  SC_Key = getKey();
  if (SC_IP == NULL || SC_Port == NULL || StringLen(SC_Key) <= 0)
    return (INIT_FAILED);

  Print("--------------------- Account Info ----------------------");
  Print("Account Number: ", AccountInfoInteger(ACCOUNT_LOGIN));
  Print("Account Server: ", AccountInfoString(ACCOUNT_SERVER));
  Print("Account Key   : ", SC_Key);
  Print("---------------------------------------------------------");

  // คำนวณข้อมูลเริ่มต้นจาก History
  CalculateAllHistoryStats();

  EventSetTimer(1);
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  EventKillTimer();
  if (Socket) {
    if (session_token != "") {
      sendLogout();
    }
    delete Socket;
    Socket = NULL;
    is_init = false;
    session_token = "";
  }
}

//+------------------------------------------------------------------+
//| Expert Timer function                                            |
//+------------------------------------------------------------------+
void OnTimer() {
  if (!Socket) {
    Socket = new ClientSocket(SC_IP, SC_Port);
    Print("Successfully connected to Stats Server");
  }

  if (Socket.IsSocketConnected()) {
    data = "";
    accInfoData = "";
    accInfoJson.Clear();
    json.Clear();

    string receiveData;
    do {
      receiveData = Socket.Receive("\r\n");
      if (receiveData != "") {
        jsonResult = json.Deserialize(receiveData);

        if (!verifyHMAC(receiveData)) {
          Print("Invalid HMAC signature - possible tampering detected!");
          continue;
        }

        if (json["cmd"] == "INIT" && json["status"] == 400) {
          sendInit(Socket);
        }

        if (json["cmd"] == "INIT" && json["status"] == 200) {
          session_token = json["session_token"].ToStr();
          token_expire = (datetime) json["expire"].ToInt();
          is_init = true;
          message_counter = 0;
          Print("Session established. Token expires at: ", TimeToString(token_expire));
        }

        if (json["cmd"] == "TOKEN_EXPIRED" || json["status"] == 401) {
          Print("Session expired. Re-initializing...");
          session_token = "";
          is_init = false;
          sendInit(Socket);
        }

        if (json["counter"].ToInt() > 0) {
          int server_counter = (int) json["counter"].ToInt();
          if (server_counter != message_counter) {
            Print("Counter mismatch - possible replay attack!");
            message_counter = server_counter;
          }
        }
      }
    } while (receiveData != "");

    if (session_token != "" && TimeGMT() >= token_expire) {
      Print("Session token expired. Re-authenticating...");
      session_token = "";
      is_init = false;
      sendInit(Socket);
    }

    // คำนวณข้อมูลใหม่ทุก 60 วินาที
    if (TimeGMT() - lastCalculateTime >= 60) {
      CalculateAllHistoryStats();
      lastCalculateTime = TimeGMT();
    }

    // ส่งข้อมูลทุก 5 วินาที
    if (TimeGMT() - lastSendTime >= 5) {
      UpdateCurrentStats();
      if (is_init && session_token != "") {
        sendAccountData(Socket);
        lastSendTime = TimeGMT();
      }
    }

  } else {
    Print("Failed to connect to Stats Server.");
    Sleep(5000);
  }

  if (!Socket.IsSocketConnected()) {
    Print("Reconnect to Stats Server.");
    delete Socket;
    Socket = NULL;
    is_init = false;
    session_token = "";
  }
}

//+------------------------------------------------------------------+
//| คำนวณสถิติทั้งหมดจาก History                                     |
//+------------------------------------------------------------------+
void CalculateAllHistoryStats() {
  // รีเซ็ตค่า
  totalDeposit = 0.0;
  totalWithdraw = 0.0;
  totalTrades = 0;
  winTrades = 0;
  lossTrades = 0;
  grossProfit = 0.0;
  grossLoss = 0.0;
  largestWin = 0.0;
  largestLoss = 0.0;
  consecutiveWins = 0;
  consecutiveLosses = 0;
  maxConsecutiveWins = 0;
  maxConsecutiveLosses = 0;
  double runningBalance = 0.0;
  double runningEquity = 0.0;
  double peakEquity = 0.0;
  maxDrawdownAmount = 0.0;

  // MT4: วนลูปผ่าน Order History
  int totalOrders = OrdersHistoryTotal();

  for (int i = 0; i < totalOrders; i++) {
    if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;

    int orderType = OrderType();
    double orderProfit = OrderProfit();
    double orderCommission = OrderCommission();
    double orderSwap = OrderSwap();
    double totalOrderProfit = orderProfit + orderCommission + orderSwap;

    // คำนวณ Deposit/Withdraw (OP_BALANCE = 6)
    if (orderType == 6) {
      if (totalOrderProfit > 0) {
        totalDeposit += totalOrderProfit;
      } else {
        totalWithdraw += MathAbs(totalOrderProfit);
      }
      runningBalance += totalOrderProfit;
    }
    // คำนวณสถิติการเทรด (OP_BUY=0, OP_SELL=1)
    else if (orderType == OP_BUY || orderType == OP_SELL) {
      // ตรวจสอบว่า order ปิดแล้ว
      if (OrderCloseTime() > 0) {
        totalTrades++;
        runningBalance += totalOrderProfit;

        if (totalOrderProfit > 0) {
          winTrades++;
          grossProfit += totalOrderProfit;
          consecutiveWins++;
          consecutiveLosses = 0;

          if (totalOrderProfit > largestWin)
            largestWin = totalOrderProfit;
          if (consecutiveWins > maxConsecutiveWins)
            maxConsecutiveWins = consecutiveWins;
        } else if (totalOrderProfit < 0) {
          lossTrades++;
          grossLoss += MathAbs(totalOrderProfit);
          consecutiveLosses++;
          consecutiveWins = 0;

          if (MathAbs(totalOrderProfit) > largestLoss)
            largestLoss = MathAbs(totalOrderProfit);
          if (consecutiveLosses > maxConsecutiveLosses)
            maxConsecutiveLosses = consecutiveLosses;
        }
      }
    }

    // คำนวณ Drawdown
    runningEquity = runningBalance;
    if (runningEquity > peakEquity)
      peakEquity = runningEquity;
    double currentDD = MathMax(0, peakEquity - runningEquity);
    if (currentDD > maxDrawdownAmount) {
      maxDrawdownAmount = currentDD;
      maxDrawdownPercent = (peakEquity > 0 ? (currentDD / peakEquity) * 100.0 : 0);
    }
  }

  // คำนวณ Net Deposit
  netDeposit = totalDeposit - totalWithdraw;
  initialDeposit = netDeposit;

  // อัพเดท max values
  double currentEquity = AccountEquity();
  double currentBalance = AccountBalance();

  if (currentEquity > maxEquity)
    maxEquity = currentEquity;
  if (currentBalance > maxBalance)
    maxBalance = currentBalance;
}

//+------------------------------------------------------------------+
//| อัพเดทข้อมูลปัจจุบัน                                            |
//+------------------------------------------------------------------+
void UpdateCurrentStats() {
  double balance = AccountInfoDouble(ACCOUNT_BALANCE);
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  double profit = AccountInfoDouble(ACCOUNT_PROFIT);
  double margin = AccountInfoDouble(ACCOUNT_MARGIN);
  double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
  double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);

  // อัพเดท max values
  if (equity > maxEquity)
    maxEquity = equity;
  if (balance > maxBalance)
    maxBalance = balance;

  // คำนวณ Drawdown ปัจจุบัน
  double currentDD = MathMax(0, maxEquity - equity);
  if (currentDD > maxDrawdownAmount) {
    maxDrawdownAmount = currentDD;
    maxDrawdownPercent = (maxEquity > 0 ? (currentDD / maxEquity) * 100.0 : 0);
  }

  // คำนวณสถิติเพิ่มเติม
  double netProfit = balance - netDeposit;
  double winRate = (totalTrades > 0 ? (winTrades * 100.0 / totalTrades) : 0);
  double avgWin = (winTrades > 0 ? grossProfit / winTrades : 0);
  double avgLoss = (lossTrades > 0 ? grossLoss / lossTrades : 0);
  double profitFactor = (grossLoss > 0 ? grossProfit / grossLoss : 0);
  double pdRatio = (maxDrawdownAmount > 0 ? netProfit / maxDrawdownAmount : 0);
  double roi = (netDeposit > 0 ? (netProfit / netDeposit) * 100.0 : 0);

  // สร้าง JSON
  accInfoJson.Clear();

  // ข้อมูลพื้นฐาน
  accInfoJson["name"] = EA_Name;
  accInfoJson["currency"] = AccountInfoString(ACCOUNT_CURRENCY);
  accInfoJson["leverage"] = (int) AccountInfoInteger(ACCOUNT_LEVERAGE);

  // ข้อมูลการเงิน
  accInfoJson["deposit"] = DoubleToString(netDeposit, 2);
  accInfoJson["totalDeposit"] = DoubleToString(totalDeposit, 2);
  accInfoJson["totalWithdraw"] = DoubleToString(totalWithdraw, 2);
  accInfoJson["balance"] = DoubleToString(balance, 2);
  accInfoJson["equity"] = DoubleToString(equity, 2);
  accInfoJson["profit"] = DoubleToString(profit, 2);
  accInfoJson["netProfit"] = DoubleToString(netProfit, 2);
  accInfoJson["margin"] = DoubleToString(margin, 2);
  accInfoJson["freeMargin"] = DoubleToString(freeMargin, 2);
  accInfoJson["marginLevel"] = DoubleToString(marginLevel, 2);

  // Drawdown
  accInfoJson["drawdown"] = DoubleToString(maxDrawdownPercent, 2);
  accInfoJson["drawdownAmount"] = DoubleToString(maxDrawdownAmount, 2);
  accInfoJson["maxEquity"] = DoubleToString(maxEquity, 2);

  // สถิติการเทรด
  accInfoJson["totalTrades"] = totalTrades;
  accInfoJson["winTrades"] = winTrades;
  accInfoJson["lossTrades"] = lossTrades;
  accInfoJson["winRate"] = DoubleToString(winRate, 2);
  accInfoJson["grossProfit"] = DoubleToString(grossProfit, 2);
  accInfoJson["grossLoss"] = DoubleToString(grossLoss, 2);
  accInfoJson["avgWin"] = DoubleToString(avgWin, 2);
  accInfoJson["avgLoss"] = DoubleToString(avgLoss, 2);
  accInfoJson["largestWin"] = DoubleToString(largestWin, 2);
  accInfoJson["largestLoss"] = DoubleToString(largestLoss, 2);
  accInfoJson["profitFactor"] = DoubleToString(profitFactor, 2);
  accInfoJson["pdRatio"] = DoubleToString(pdRatio, 2);
  accInfoJson["roi"] = DoubleToString(roi, 2);
  accInfoJson["maxConsecutiveWins"] = maxConsecutiveWins;
  accInfoJson["maxConsecutiveLosses"] = maxConsecutiveLosses;

  accInfoJson["date"] = TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS);
  accInfoJson["timestamp"] = (long) TimeGMT();

  accInfoJson.Serialize(accInfoData);
}

//+------------------------------------------------------------------+
//| Get Account Key                                                  |
//+------------------------------------------------------------------+
string getKey() {
  long login = AccountInfoInteger(ACCOUNT_LOGIN);
  string server = AccountInfoString(ACCOUNT_SERVER);
  string src;
  if (StringLen(SC_Secret) > 0)
    src = IntegerToString(login) + "|" + server + "|" + SC_Secret;
  else
    src = IntegerToString(login) + "|" + server;

  uchar src_bytes[];
  StringToCharArray(src, src_bytes, 0, WHOLE_ARRAY, CP_UTF8);
  ArrayResize(src_bytes, ArraySize(src_bytes) - 1);

  uchar hash_bytes[];
  uchar empty_key[];

  int res = CryptEncode(CRYPT_HASH_SHA256, src_bytes, empty_key, hash_bytes);
  if (res <= 0) {
    Print("Get account key failed");
    return ("");
  }

  string hex = "";
  for (int i = 0; i < ArraySize(hash_bytes); i++)
    hex += StringFormat("%02X", hash_bytes[i]);

  return (hex);
}

//+------------------------------------------------------------------+
//| HMAC Functions                                                    |
//+------------------------------------------------------------------+
uchar HexCharToByte(uchar c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
  if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
  return 0;
}

void HexStringToBytes(string hex, uchar & bytes[]) {
  int len = StringLen(hex);
  ArrayResize(bytes, len / 2);
  for (int i = 0; i < len / 2; i++)
    bytes[i] = (HexCharToByte(StringGetCharacter(hex, i * 2)) << 4) |
    HexCharToByte(StringGetCharacter(hex, i * 2 + 1));
}

string generateHMAC(string message, string hexKey) {
  uchar key_bytes[];
  HexStringToBytes(hexKey, key_bytes);

  int BLOCKSIZE = 64;
  if (ArraySize(key_bytes) > BLOCKSIZE) {
    uchar tmp[];
    SHA256 sha;
    sha.init();
    sha.update(key_bytes, ArraySize(key_bytes));
    ArrayResize(tmp, 32);
    sha.end(tmp);
    ArrayResize(key_bytes, 32);
    ArrayCopy(key_bytes, tmp);
  }

  if (ArraySize(key_bytes) < BLOCKSIZE) {
    int oldLen = ArraySize(key_bytes);
    ArrayResize(key_bytes, BLOCKSIZE);
    ArrayFill(key_bytes, oldLen, BLOCKSIZE - oldLen, 0);
  }

  uchar i_key_pad[], o_key_pad[];
  ArrayCopy(i_key_pad, key_bytes);
  ArrayCopy(o_key_pad, key_bytes);
  for (int i = 0; i < BLOCKSIZE; i++) {
    i_key_pad[i] ^= 0x36;
    o_key_pad[i] ^= 0x5c;
  }

  uchar msg_bytes[];
  int msg_len = StringToCharArray(message, msg_bytes, 0, StringLen(message), CP_UTF8);

  uchar i_data[];
  ArrayResize(i_data, BLOCKSIZE + msg_len);
  ArrayCopy(i_data, i_key_pad);
  ArrayCopy(i_data, msg_bytes, BLOCKSIZE);

  uchar inner_hash[];
  SHA256 sha_inner;
  sha_inner.init();
  sha_inner.update(i_data, ArraySize(i_data));
  ArrayResize(inner_hash, 32);
  sha_inner.end(inner_hash);

  uchar o_data[];
  ArrayResize(o_data, BLOCKSIZE + ArraySize(inner_hash));
  ArrayCopy(o_data, o_key_pad);
  ArrayCopy(o_data, inner_hash, BLOCKSIZE);

  SHA256 sha_outer;
  sha_outer.init();
  sha_outer.update(o_data, ArraySize(o_data));
  uchar final_hash[32];
  sha_outer.end(final_hash);

  string result = "";
  for (int i = 0; i < 32; i++)
    result += StringFormat("%02x", final_hash[i]);

  return result;
}

//+------------------------------------------------------------------+
//| Verify HMAC                                                       |
//+------------------------------------------------------------------+
bool verifyHMAC(string received_data) {
  if (session_token == "" && !is_init) return true;

  string received_hmac = json["hmac"].ToStr();
  if (received_hmac == "") return true;

  string verify_data = "";
  CJAVal temp_json;

  if (json["cmd"].ToStr() != "") temp_json["cmd"] = json["cmd"].ToStr();
  if (json["status"].ToInt() > 0) temp_json["status"] = (int) json["status"].ToInt();
  if (json["session_token"].ToStr() != "") temp_json["session_token"] = json["session_token"].ToStr();
  if (json["expire"].ToInt() > 0) temp_json["expire"] = (long) json["expire"].ToInt();
  if (json["counter"].ToInt() > 0) temp_json["counter"] = (int) json["counter"].ToInt();
  if (json["message"].ToStr() != "") temp_json["message"] = json["message"].ToStr();
  if (json["data"].ToStr() != "") temp_json["data"] = json["data"].ToStr();

  temp_json.Serialize(verify_data);
  string calculated_hmac = generateHMAC(verify_data, session_token != "" ? session_token : SC_Key);

  return (calculated_hmac == received_hmac);
}

//+------------------------------------------------------------------+
//| Send Init                                                         |
//+------------------------------------------------------------------+
void sendInit(ClientSocket * sender) {
  if (!is_init) {
    message_counter = 0;

    string nonce = IntegerToString(GetTickCount());

    CJAVal init_json;
    init_json["type"] = "EA";
    init_json["cmd"] = "INIT";
    init_json["nonce"] = nonce;
    init_json["timestamp"] = (long) TimeGMT();
    init_json["account"] = (long) AccountInfoInteger(ACCOUNT_LOGIN);
    init_json["server"] = AccountInfoString(ACCOUNT_SERVER);

    string temp_data;
    init_json.Serialize(temp_data);

    string signature = generateHMAC(temp_data, SC_Key);
    init_json["hmac"] = signature;

    init_json.Serialize(data);
    sender.Send(data + "\r\n");
    Print("Send Init to Stats Server");
  }
}

//+------------------------------------------------------------------+
//| Send Logout                                                       |
//+------------------------------------------------------------------+
void sendLogout() {
  if (session_token != "" && Socket.IsSocketConnected()) {
    message_counter++;

    CJAVal logout_json;
    logout_json["cmd"] = "LOGOUT";
    logout_json["session"] = session_token;
    logout_json["counter"] = message_counter;
    logout_json["timestamp"] = (long) TimeGMT();

    string temp_data;
    logout_json.Serialize(temp_data);

    string signature = generateHMAC(temp_data, session_token);
    logout_json["hmac"] = signature;

    logout_json.Serialize(data);
    Socket.Send(data + "\r\n");
    Print("Send Logout");
  }
}

//+------------------------------------------------------------------+
//| Send Account Data                                                 |
//+------------------------------------------------------------------+
void sendAccountData(ClientSocket * sender) {
  message_counter++;

  CJAVal send_json;
  send_json["cmd"] = "ACCINFO";
  send_json["session"] = session_token;
  send_json["counter"] = message_counter;
  send_json["timestamp"] = (long) TimeGMT();
  send_json["data"] = accInfoData;

  string temp_data;
  send_json.Serialize(temp_data);

  string signature = generateHMAC(temp_data, session_token);
  send_json["hmac"] = signature;

  send_json.Serialize(data);
  sender.Send(data + "\r\n");
}
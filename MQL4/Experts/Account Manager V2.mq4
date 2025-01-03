//+------------------------------------------------------------------+
//|                                           Account Manager V2.mq4 |
//|                                 Copyright 2024,Titivoot Pangrit. |
//|                                     https://github.com/Titivoot/ |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024,Titivoot Pangrit."
#property link      "https://github.com/Titivoot/"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Expert import library                                            |
//+------------------------------------------------------------------+
#include <Socket.mqh>
#include <JAson.mqh>

//+------------------------------------------------------------------+
//| Expert input parameters                                          |
//+------------------------------------------------------------------+
input string   _SC1 = "------------------- Server Config -------------------"; // ---
input string   SC_IP = "127.0.0.1"; // Server IP
input ushort      SC_Port = 7171; // Server Port
input string   SC_Key = "04M16JmlVlWvFGBWJN3I3ZcyM6iIvRkt"; // Client Key
input string   _SC2 = "---------------------------------------------------------------"; // ---

// --------------------------------------------------------------------
// Global variables and constants
// --------------------------------------------------------------------

ClientSocket * glbClientSocket = NULL;

CJAVal json;
string jsonOut;
bool jsonResult;

CJAVal accData;
string accDataOut;
bool accDataResult;

bool isINIT = false;

double MaxEquity = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
  return(INIT_SUCCEEDED);
  if (SC_IP == NULL || SC_Port == NULL || SC_Key == NULL || StringLen(SC_Key) < 10) return (INIT_FAILED);
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  // Disconnect Server
  if (glbClientSocket) {
    delete glbClientSocket;
    glbClientSocket = NULL;
    isINIT = false;
  }
}
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
  // Connect Server
  if (!glbClientSocket) {
    glbClientSocket = new ClientSocket(SC_IP, SC_Port);
    if (glbClientSocket.IsSocketConnected()) {
      Print("Client connection succeeded");
    } else {
      Print("Client connection failed");
    }
  }
  
  // Main function
  if (glbClientSocket.IsSocketConnected()) {
    // clear json
    jsonOut = "";
    accDataOut = "";
    
    // update account data
    updateAccountData();
    
    // Receive data from server
    string resData;
    do {
      resData = glbClientSocket.Receive("\r\n");
      if (resData != "") {
        jsonResult = json.Deserialize(resData);
        // init commands
        if (json["key"] == "" && json["cmd"] == "INIT" && json["status"] == 400) sendInit(glbClientSocket);
        
        if (json["key"] == SC_Key && json["cmd"] != "") {
          if (json["cmd"] == "INIT") {
            if (json["status"] == 200) isINIT = true;
          }
          
          if (json["cmd"] == "ACCINFO") {
          //  if (json["status"] == 200) Print("Send AccountData Complete.");
          }
          
        }
      }
    } while (resData != "");
    
    if (isINIT) {
      sendAccountData(glbClientSocket); // send account data to web
    }
  }
  
  // Check Connection
  if (!glbClientSocket.IsSocketConnected()) {
    Print("Client disconnected. Will retry.");
    delete glbClientSocket;
    glbClientSocket = NULL;
    isINIT = false;
  }
}

//+------------------------------------------------------------------+
//| Calculate drawdown function                                             |
//+------------------------------------------------------------------+
string CalculateDrawdown() {
   if(OrdersTotal() == 0) {
       MaxEquity = AccountEquity();
   } else if (AccountEquity() > MaxEquity) {
      MaxEquity = AccountEquity();
   }
   return DoubleToStr(((MaxEquity - AccountEquity()) / MaxEquity) * 100, 2) + "%";
}

//+------------------------------------------------------------------+
//| send key to server function                                      |
//+------------------------------------------------------------------+
void sendInit(ClientSocket * sender) {
  if (!isINIT) {
    json["key"] = SC_Key;
    json["type"] = "EA";
    json["cmd"] = "INIT";
    json.Serialize(jsonOut);
    sender.Send(jsonOut);
    Print("Client INIT");
  }
}

//+------------------------------------------------------------------+
//| update account data json function                                |
//+------------------------------------------------------------------+
void updateAccountData() {
  accData["key"] = SC_Key;
  accData["accountNumber"] = AccountNumber();
  accData["accountType"] = AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DEMO" : "REAL";
  accData["Balance"] = AccountBalance();
  accData["Equity"] = AccountEquity();
  accData["Profit"] = AccountProfit();
  accData["Drawdown"] = CalculateDrawdown();
  accData["Date"] = TimeToString(TimeLocal(), TIME_DATE|TIME_SECONDS);
  accData.Serialize(accDataOut);
}

//+------------------------------------------------------------------+
//| send account data to server function                             |
//+------------------------------------------------------------------+
void sendAccountData(ClientSocket * sender) {
  json["key"] = SC_Key;
  json["cmd"] = "ACCINFO";
  json["data"] = accDataOut;
  json.Serialize(jsonOut);
  sender.Send(jsonOut);
}

//+------------------------------------------------------------------+

const net = require("net");
const WebSocket = require('ws');

require('dotenv').config()

let websocketClients = []; // เก็บ client ของ websocket
let socketClients = []; // เก็บ client ของ socket
let accountData = []; // เก็บข้อมูล account ทั้งหมดที่ได้รับจาก EA

// Websocket Server
const websocket = new WebSocket.Server({ port: process.env.WEBSOCKET_PORT });
websocket.on('connection', (client) => {
    client.clientInfo = {
        "key": "", // เอาไว้ให้ยืนยันตัวตนว่าเป็น server
        "keys": null, // client ต้องส่ง key ของ EA ที่ต้องการรับข้อมูล
        "type": "" // Client, Server
    };

    websocketClients.push(client);
    console.log(`${client._socket.remoteAddress}:${client._socket.remotePort} joined to Websocket Server.`);

    // ส่งคำสั่งขอ key จาก client
    client.send(JSON.stringify({
        "cmd": "INIT",
        "status": 400
    }));

    // ถ้าไม่มีการส่ง key ภายใน 10 วินาทีให้เตะออกจากเซิฟเวอร์
    setTimeout(() => {
        if (client.clientInfo["key"] == "" && client.clientInfo["type"] == "Server") {
            client.resetAndDestroy();
        }
        if (client.clientInfo["keys"] == null && client.clientInfo["type"] == "Client") {
            client.resetAndDestroy();
        }
    }, 10 * 1000);

    client.on('message', (data) => {
        if (isJson(data)) {
            let json = JSON.parse(data.toString());
            switch(json["cmd"]) {
                case "INIT":
                     // บันทึก key และ type ลง client
                    client.clientInfo["key"] = json["key"];
					client.clientInfo["keys"] = json["keys"];
					client.clientInfo["type"] = json["type"];

					console.log(`${client._socket.remoteAddress}:${client._socket.remotePort} (WEBSOCKET) has been init.`);

                    // ส่งคำสั่งบอกว่าได้รับข้อมูลแล้ว
                    client.send(JSON.stringify({
                        "cmd": "INIT",
                        "status": 200
                    }));
					break;

                // คำสั่งขอข้อมูล Account
                case "ACCINFO":
                    // เช็คว่า client ได้ INIT หรือยัง
                    switch(client.clientInfo["type"]) {
                        case "Server":
                            if (client.clientInfo["key"] == process.env.SERVER_KEY) {
                                // บันทึก accountData
                                if (accountData.length == 0) {
                                    accountData.push(json["data"]);
                                } else {
                                    const index = accountData.findIndex(ac => ac.accountNumber == json["data"]["accountNumber"]);
                                    if (index !== -1) {
                                        accountData[index] = json["data"];
                                    } else {
                                        accountData.push(json["data"]);
                                    }
                                }
                            }

                            // ส่งข้อมูลให้ client
                            if (accountData.length > 0) {
                                websocketClients.forEach(wc => {
                                    let keys = Object(wc.clientInfo["keys"]);
                                    if (keys.length > 0) {
                                        let data = accountData.filter(item => keys.includes(item.key)).map(({ key, ...data }) => data);
                                        if (data.length > 0) {
                                            wc.send(JSON.stringify({
                                                "cmd": "ACCINFO",
                                                "status": 200,
                                                "data": data
                                            }));
                                        }
                                    }
                                });
                            }
                            break;
                        case "Client":
                            if (client.clientInfo["keys"] != null && client.clientInfo["keys"].length > 0) {
                                let data = accountData.filter(item => client.clientInfo["keys"].includes(item.key)).map(({ key, ...data }) => data);
                                client.send(JSON.stringify({
                                    "cmd": "ACCINFO",
                                    "status": 200,
                                    "data": data
                                }));
                            }
                            break;
                        default:
                            console.log(`${client._socket.remoteAddress}:${client._socket.remotePort} (WEBSOCKET) send invalid format data.`);
                            //client.close();
                            break;
                    }
                    break;
                default:
                    console.log(`${client._socket.remoteAddress}:${client._socket.remotePort} (WEBSOCKET) send invalid format data.`);
                    //client.close();
                    break;
            }
        }
    });

    client.on('close', () => {
        console.log(`${client._socket.remoteAddress}:${client._socket.remotePort} left the WebSocket Server.`);
        if (client.clientInfo["type"] != "Server") {
          websocketClients.splice(websocketClients.indexOf(client), 1);
        }
    });

    client.on('error', (err) => {
        console.log(err);
    });
});

// Socket Server
net.createServer((client) => {
    client.clientInfo = {
        "key": "", // key ยืนยันตัวตนไว้ใช้สำหรับรับส่งข้อมูล
        "type": "" // EA, Server
    }
    socketClients.push(client);

    console.log(`${client.remoteAddress}:${client.remotePort} joined to Socket Server.`);

    // ส่งคำสั่งขอ key จาก client
    client.write(JSON.stringify({
        "cmd": "INIT",
        "status": 400
    }) + "\r\n");

    // ถ้าไม่มีการส่ง key ภายใน 10 วินาทีให้เตะออกจากเซิฟเวอร์
    setTimeout(() => {
        if (client.clientInfo["key"] == "") {
            client.resetAndDestroy();
        }
    }, 10 * 1000);

    client.on("data", (data) => {
        if (isJson(data.toString())) {
            let json = JSON.parse(data.toString());
            switch(json["cmd"]) {
                // คำสั่ง init เพื่อบอก server ว่าเป็น type ไหน (EA, Server)
                // -----
                // type EA เป็นการบอก server ว่า คือการเชื่อมต่อจาก EA 
                // ถ้าจะส่งคำสั่งให้ EA ต้องต่อท้ายด้วย \r\n เพิ่มบอก EA ว่าจบบรรทัดแล้ว
                // -----
                // type Server เป็นการบอก server ว่า คือการเชื่อมต่อจากตัว Server เอง
                // ตัวนี้ใช้ในการควบคุม EA ทั้งหมดใน Server ห้ามทำ key หลุด
                // -----
                case "INIT":
                    // บันทึก key และ type ลง client
					client.clientInfo["key"] = json["key"];
					client.clientInfo["type"] = json["type"];
					console.log(`${client.remoteAddress}:${client.remotePort} (SOCKET) has been init.`);

                    // ส่งคำสั่งบอกว่าได้รับข้อมูลแล้ว
                    client.write(JSON.stringify({
                        "key": client.clientInfo["key"],
                        "cmd": "INIT",
                        "status": 200
                    }) + "\r\n");
					break;

                // คำสั่งขอข้อมูล Account ที่ client ตัวนั้นเชื่อมต่อ
                case "ACCINFO":
                    // เช็คว่า client ได้ INIT หรือยัง
                    if (client.clientInfo["key"] != "" && json["key"] == client.clientInfo["key"] && client.clientInfo["type"] == "EA") {
                        client.accountData = JSON.parse(json["data"]);

                        // ส่งข้อมูลให้กับ type Server
                        socketClients.forEach(sc => {
                            if (sc.clientInfo["key"] == process.env.SERVER_KEY && sc.clientInfo["type"] == "Server") {
                                sc.write(JSON.stringify({
                                    "cmd": "ACCINFO",
                                    "data": client.accountData
                                }));
                            }
                        });

                        // ตอบกลับ client ว่าได้รับข้อมูลแล้ว
                        client.write(JSON.stringify({
                            "key": client.clientInfo["key"],
                            "cmd": "ACCINFO",
                            "status": 200
                        }) + "\r\n");
                    } else {
                        console.log(`${client.remoteAddress}:${client.remotePort} (SOCKET) try send data without init.`);
                        //client.resetAndDestroy();
                    }
                    break;
                default:
                    console.log(`${client.remoteAddress}:${client.remotePort} (SOCKET) send invalid format data.`);
                    console.log(data.toString())
                    //client.resetAndDestroy();
                    break;
            }
        } else {
			console.log(`${client.remoteAddress}:${client.remotePort} (SOCKET) send invalid format data.`);
            console.log(data.toString())
            //client.resetAndDestroy();
		}
    });

    client.on("end", () => {
		console.log(`${client.remoteAddress}:${client.remotePort} left the Socket Server.`);
		socketClients.splice(socketClients.indexOf(client), 1);
	});
	
	client.on("error", (err) => {
		console.log(err);
	});

}).listen(process.env.SOCKET_PORT);


// สร้าง Socket Client ไว้ดึงข้อมูลจาก Socket ส่งให้ Websocket
// และติดต่อกับ ea
const startClient = () => {
    const websocket = new WebSocket(`ws://localhost:${process.env.WEBSOCKET_PORT}`);

    websocket.onopen = () => {
        websocket.send(JSON.stringify({
            "key": process.env.SERVER_KEY,
            "type": "Server",
            "cmd": "INIT"
        }));
    };

    const client = net.createConnection({ port: process.env.SOCKET_PORT }, () => {
        client.write(JSON.stringify({
            "key": process.env.SERVER_KEY,
            "type": "Server",
            "cmd": "INIT"
        }) + "\r\n");
    });

    client.on('data', (data) => {
        if (isJson(data.toString())) {
            let json = JSON.parse(data.toString());
            switch(json["cmd"]) {
                // คำสั่งส่งต่อข้อมูลให้ websocket
                case "ACCINFO":
                    // เช็คว่า client ได้ INIT หรือยัง
                    if (json["data"] != "") {
                        websocket.send(JSON.stringify({
                            "cmd": "ACCINFO",
                            "data": json["data"]
                        }));
                    }
                    break;
            }
        }
    });

    client.on('end', () => {
        console.log('disconnected from server');
    });
};

startClient();

const isJson = (str) => {
    try {
        JSON.parse(str);
    } catch (e) {
        return false;
    }  
    return true;
}

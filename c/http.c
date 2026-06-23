#include "inc/http.h"

/*
 * Content-Length 计算规则：
 * 仅从 HTML 内容第一个字符（如 "<meta" 或 "<html>"）开始计算字节数。
 * HTTP 状态行 + 各头部字段 + 空行（\r\n\r\n）不计入 Content-Length。
 *
 * 修改 HTML 内容后，必须同步更新 Content-Length 值，否则：
 *   GET  → 浏览器持续刷新/打转
 *   POST → 客户端收到响应后可能不渲染或立即断链
 *
 * 当前 Content-Length 验证方法：Wireshark 抓包后
 *   Content-Length = 总包长 - (状态行 + 头部行 + 空行) 字节数
 */

const char *main_page =
    "HTTP/1.1 200 OK\r\n"
    "Content-Length: 1288\r\n"
    "Content-Type: text/html\r\n\r\n"
    "<meta charset='UTF-8'><html><head><title>Web@RiscV@FPGA</title>"
    "<style>"
    "body{text-align:center;margin:30px;}"
    ".title{margin-bottom:10px;font-weight:bold;}"
    ".config{border:1px;display:inline-block;}"
    "input,button{width:180px;padding:8px;margin:5px;font-size:16px;}"
    "label{cursor:pointer;font-size:15px;}"
    "label input[type=radio]{width:auto;margin:0 30px 0 0;}"
    ".footer{margin-top:30px;font-size:14px;color:#555;}"
    "</style></head><body>"
    "<div class='title'>RiscV@FPGA嵌入式控制</div>"
    "<div class='config'>"
    "<input id='addr' placeholder='Addr(HEX)'><br>"
    "<input id='data' placeholder='Data (HEX)'><br>"
    "<label><input type='radio' name='mode' id='read' checked>读</label><br>"
    "<label><input type='radio' name='mode' id='write'>写</label><br>"
    "<button onclick='sendData()'>Confirm</button>"
    "</div>"
    "<div class='footer'>Copy Right @ Buck 2026</div>"
    "<script>"
    "function sendData(){"
    "let a=document.getElementById('addr').value;"
    "let d=document.getElementById('data').value;"
    "let mode=document.getElementById('read').checked?'read':'write';"
    "fetch('/submit',{method:'POST',headers:{'Content-Type':'application/json'},"
    "body:JSON.stringify({addr:a,data:d,mode:mode})})"
    ".then(response=>response.text())"
    ".then(html=>{document.open();document.write(html);document.close();})"
    ".catch(error=>console.error('Error:',error));}"
    "</script></body></html>";

const char *post_response =
    "HTTP/1.1 200 OK\r\n"
    "Content-Length: 520\r\n"
    "Connection: keep-alive\r\n"
    "Content-Type: text/html\r\n\r\n"
    "<html>\r\n"
    "<head><meta charset='UTF-8'>"
    "<style>"
    "body{text-align:center;margin:30px;}"
    ".msg{margin:20px;font-size:18px;line-height:1.8;}"
    ".title{font-weight:bold;color:#2196F3;font-size:22px;}"
    ".detail{font-size:14px;color:#666;}"
    "button{width:180px;padding:8px;margin:5px;font-size:16px;}"
    "</style></head>\r\n"
    "<body>\r\n"
    "<div class='msg'><span class='title'>XXX操作成功！</span><br><span class='detail'>XXX地址是：0x00000000<br>XXX数据是：0x88888888</span></div>\r\n"
    "<button onclick=\"location='/'\">确定</button>\r\n"
    "</body>\r\n"
    "</html>";

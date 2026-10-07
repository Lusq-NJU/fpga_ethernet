# ethernet_tx_pack 模块验证报告

- **验证对象**：`project_ethernet.srcs/sources_1/new/ethernet_tx_pack.v`
- **依据文档**：`tx_pack功能文档.pdf`（千兆网接口 tx_pack 功能文档，共 4 页）
- **验证方式**：Vivado 2020.2 xsim，使用真实 IP 行为模型（`fifo_19x65536_fwft_sync` / `fifo_32x128_fwft_sync`）进行 RTL 仿真
- **报告日期**：2026-10-07（第一轮）；第二轮复核及校验和时序分析；第三轮校验和实现复核

---

## 目录

1. [验证环境与方法](#一验证环境与方法)
2. [验证结论](#二验证结论)
3. [问题清单](#三问题清单)
4. [校验和实现参考](#四校验和实现参考)
5. [修正版验证结果](#五修正版验证结果)
6. [修改后代码复核（第二轮验证）](#六修改后代码复核第二轮验证2026-10-07)
7. [校验和时序分析与优化](#七校验和时序分析与优化实测)
8. [第三轮验证：校验和实现复核](#八第三轮验证2026-10-07校验和实现复核)
9. [建议修改顺序](#九建议修改顺序第三轮更新)
10. [附录](#附录)

---

## 一、验证环境与方法

### 1.1 仿真环境

| 项目 | 内容 |
|---|---|
| 仿真器 | Vivado Simulator 2020.2（Windows 版，WSL 下经 `cmd.exe` 调用） |
| 器件 | xc7k70tfbg676-2 |
| 时钟 | 100 MHz（周期 10 ns） |
| FIFO 模型 | 真实 IP `*_sim_netlist.v` + unisims_ver 预编译库 + `glbl.v` |

### 1.2 测试平台

`sim_verify/tb_compare.v` 同时实例化**原版**与**修正版**（`ethernet_tx_pack_ref.v`），施加相同激励，逐拍打印输出并对比。

| 用例 | 内容 | 数据 |
|---|---|---|
| CASE1 | 文档第 4 页举例 | `0x000a, 0x0001, 0x0014`（3 拍，mty=0） |
| CASE2 | 奇数长度 | `0x0011`, `0x2200`（mty=1，共 3 字节） |
| CASE3 | 背靠背两包 | `0xaaaa`、`0xbbbb`（各 1 拍，连续发送） |
| CASE4 | 长包 | 64 拍 = 128 字节（`0x0101`~`0x0140`） |

固定配置：

```
cfg_dmac  = 48'h0102_0304_0506      cfg_smac  = 48'h2c02_0304_0507
cfg_sip   = 32'hc0a8_010a           cfg_dip   = 32'hc0a8_0109
cfg_sport = 16'h1388                cfg_dport = 16'h0bb8
```

### 1.3 期望值计算

期望包文由 Python 按文档规则独立计算（1 的补码和 + 进位回卷 + 取反），与仿真输出逐字比对。

---

## 二、验证结论

> **当前模块无法完成指定功能。**
>
> 1. 状态机永远卡在 UDP 状态，**数据永远不会发出**（`w_udp2data_start` 未赋值）；
> 2. 即使跳过该问题，IP/UDP 包头也会因**拼接表达式位宽错误**而整体错位；
> 3. IP/UDP 校验和未实现（已知），且数据校验和的折叠逻辑存在进位漏洞。

修正全部问题后，模块输出与文档第 4 页示例**逐字吻合**（详见[第五节](#五修正版验证结果)）。

---

## 三、问题清单

### 3.1 致命问题

#### ① `w_udp2data_start` 从未赋值

**位置**：`ethernet_tx_pack.v:249-259`（状态切换信号的 assign 区域）

扫描全模块 40 个 wire/reg 声明确认：`w_idle2mac_start`、`w_mac2ip_start`、`w_ip2udp_start`、`w_data2idle_start` 均有赋值，**唯独 `w_udp2data_start` 只声明、无赋值**：

```verilog
wire                    w_udp2data_start    ;   // ← 声明了

assign w_idle2mac_start = r_state_c==IDLE && dout_rdy && w_message_empty==0;
assign w_mac2ip_start = r_state_c==MAC && w_end_cnt_mac;
assign w_ip2udp_start = r_state_c==IP && w_end_cnt_ip;
// assign w_udp2data_start = ...;   ← 缺失！

assign w_data2idle_start = r_state_c==DATA && w_message_rd_en;
```

**后果**：`case` 语句中 `if(w_udp2data_start)` 恒为假（悬空值），`UDP → DATA` 状态转换永不发生。

**仿真现象**：UDP 状态以 8 拍为一轮**无限循环**，数据一个字节都发不出（原版实测连续输出 288 拍，全部是 UDP 头的重复）。

**修复**：

```verilog
assign w_udp2data_start = r_state_c==UDP && w_end_cnt_udp;
```

#### ② UDP 状态拍数写错

**位置**：`ethernet_tx_pack.v:232`

```verilog
assign w_end_cnt_udp = w_add_cnt_udp && r_cnt_udp==8-1  ;   // ✗ 错误
```

UDP 头 8 **字节** = 4 个 16 位字 = **4 拍**，应写 `4-1`。
对照其他计数器可确认这是笔误：MAC 头 14 字节 → `7-1` ✓，IP 头 20 字节 → `10-1` ✓，只有 UDP 把"字节数"当成了"拍数"。

**后果**：
- UDP 状态多发 4 拍；
- 位选 `w_udp_head[63-r_cnt_udp*16 -: 16]` 在 `r_cnt_udp≥4` 时出现**负索引**（如 `[63-64-:16]`），输出恒为 `x`。

**修复**：

```verilog
assign w_end_cnt_udp = w_add_cnt_udp && r_cnt_udp==4-1  ;
```

### 3.2 严重问题

#### ③ 拼接表达式位宽陷阱（隐藏最深）

**位置**：`ethernet_tx_pack.v:195-196`（IP 头）、`224-225`（UDP 头）

```verilog
assign w_ip_head = {4'd4, 4'd5, 8'd0, 20+w_message_dout[31:16], r_cnt_id, ...};
//                                      ^^^^ unsized 常量
```

Verilog 中 `20` 是无位宽常量，与 16 位信号相加时整个表达式取 **32 位**，导致拼接宽度变为：

```
4+4+8+32+16+3+13+8+8+16+32+32 = 176 位  ≠  声明宽度 160 位
```

赋值时**高 16 位被截断丢弃** → IP 头整体左移 16 位，`0x4500`（版本+首部长度）直接消失。

**独立实验证据**（xsim 实测）：

```verilog
{4'hA, a + 1}       // a=16'h0001 → 拼接 36 位 → 截断后 0x00000002
{4'hA, a + 16'd1}   // a=16'h0001 → 拼接 20 位 → 0x000A0002
```

**后果一览**：

| 语句 | 实际拼接宽度 | 声明宽度 | 影响 |
|---|---|---|---|
| `w_ip_head_tmp` / `w_ip_head` | 176 位 | 160 位 | IP 头左移 16 位，首字丢失 |
| `w_udp_head_tmp` | 192 位 | 160 位 | 伪首部+UDP头左移 32 位 |
| `w_udp_head` | 80 位 | 64 位 | 源端口丢失，整体左移 16 位 |

**修复**：所有参与拼接的算术表达式使用显式位宽常量，例如：

```verilog
wire [15:0] w_ip_total_len = 16'd20 + w_udp_len;   // 明确 16 位
wire [15:0] w_udp_len      = 16'd8  + ...;         // 明确 16 位
...
assign w_ip_head = {4'd4, 4'd5, 8'd0, w_ip_total_len, r_cnt_id, ...};   // 160 位
```

> **同类写法自查清单**：凡拼接中出现 `8+...`、`20+...`、`8-1`、`20+w_message_dout[31:16]` 等，一律补显式位宽。

#### ④ `w_message_din` 33 位截断

**位置**：`ethernet_tx_pack.v:62, 146`

```verilog
reg  [16:0] r_check_res_tmp;                             // 17 位
wire [31:0] w_message_din;
assign w_message_din = {w_data_len, r_check_res_tmp};    // 16+17 = 33 位 → 截断
```

**后果**：截断到 32 位后长度字段整体错位——数据校验和的最高位挤入长度字段，长度值也发生移位。仿真中 UDP 长度字段输出 `0x0014`（20），正确值应为 `0x000e`（14）。

**修复**：`r_check_res_tmp` 收窄为 16 位（折叠后本就 ≤ 0xFFFF），使拼接恰为 32 位：

```verilog
reg  [15:0] r_check_res_tmp;
assign w_message_din = {w_data_bytes, r_check_res_tmp};   // 16+16 = 32 位 ✓
```

#### ⑤ IP 标识（ID）递增时机错误

**位置**：`ethernet_tx_pack.v:31-36`

```verilog
always @(posedge clk or negedge rst_n) begin
    if(rst_n==0)      r_cnt_id <= 0;
    else if(tx_eop)   r_cnt_id <= r_cnt_id+1;   // 收完数据立即 +1
end
```

包头是在数据接收**之后**才发送的，此时 `r_cnt_id` 已加过 1，导致发出的永远是"下一个包"的 ID。文档示例首包 ID 应为 `0x0000`，原实现会输出 `0x0001`。

**修复**：改为整包发送完毕后再递增：

```verilog
always @(posedge clk or negedge rst_n) begin
    if(rst_n==0)
        r_cnt_id <= 0;
    else if(w_data2idle_start)          // 包发送完毕
        r_cnt_id <= r_cnt_id+1;
end
```

（另建议把 `else if(tx_eop)` 一并写成 `else if(tx_vld && tx_eop)`，避免 eop 长时间拉高时误计数。）

#### ⑥ 校验和未实现 + 取反约定不一致

**位置**：`ethernet_tx_pack.v:193, 222`

`w_ip_head_check`、`w_udp_head_check` 声明后从未驱动 → 校验和字段输出 `x`。

同时注意两处取反写法**不一致**：

```verilog
assign w_ip_head  = {..., ~w_ip_head_check, ...};   // 有取反
assign w_udp_head = {..., w_udp_head_check};        // 无取反
```

**实现时必须统一**：建议两个信号都定义为"**已取反的最终校验和**"，使用时直接放置（参考代码见[第四节](#四校验和实现参考)）。

#### ⑦ 数据校验和折叠的二次进位漏洞

**位置**：`ethernet_tx_pack.v:72-81`

```verilog
r_check_res_tmp = r_check_res+tx_data;
r_check_res_tmp[0] = r_check_res_tmp[0]+r_check_res_tmp[16];   // 问题所在
```

`r_check_res_tmp[0]` 是 1 位，当 `bit0=1` 且进位 `bit16=1` 时，`1+1=2` 被截断为 0，**进位丢失**（例如 `0x0001 + 0x0001` 的折叠会算错）。

**修复**：用整体加法让进位正确落到 bit1：

```verilog
wire [16:0] w_chk_sum   = {1'b0, r_check_res} + {1'b0, w_check_word};
wire [16:0] w_chk_fold1 = w_chk_sum[15:0]   + w_chk_sum[16];
wire [15:0] w_chk_fold2 = w_chk_fold1[15:0] + w_chk_fold1[16];   // 二次回卷
```

#### ⑧ 奇数长度（mty=1）未屏蔽无效字节

**位置**：`ethernet_tx_pack.v:68-81`

`r_check_res` 直接累加整个 `tx_data`。当 `mty=1` 时最后一拍只有 1 个有效字节，无效字节若为非零值，UDP 校验和必然出错。

**修复**：显式补零（与本模块"高字节先发"的输出约定一致）：

```verilog
assign w_check_word = (tx_eop && tx_mty) ? {tx_data[15:8], 8'h00} : tx_data;
```

> ⚠️ 该约定需与**上游数据产生模块**确认：mty=1 时有效字节是高 8 位（本模块输出 MAC 头时高字节先发，故取高字节）。

### 3.3 次要问题

#### ⑨ 文档与代码的外部不一致（需确认）

**a. 信号命名差异**

| 文档 | 代码 |
|---|---|
| `cfg_mac_s` / `cfg_mac_d` | `cfg_smac` / `cfg_dmac` |
| `dout` | `dout_data` |

功能相同，仅在顶层例化/交接时注意对应关系。

**b. 文档自身矛盾：IP 标志位**

- 文档文字："标志占 3 位，**固定为 0**；片偏移(13 位)，固定为 0"
- 文档第 4 页示例：IP 头第 4 个字为 **`0x4000`**（DF=1）

用 Python 反推验证：**只有取 `0x4000` 才能得到示例中的校验和 `0xf866`**；取 `0x0000` 时校验和为 `0x3867`。

当前代码按文字实现（`3'd0, 13'd0` → `0x0000`）。若要复现文档示例，改写为：

```verilog
3'b010, 13'd0      // = 16'h4000，DF(不分片)置位
```

#### ⑩ 其他注意事项

| 项目 | 说明 |
|---|---|
| `dout_rdy` 检查时机 | 仅在 IDLE 状态检查，包发送过程中下游撤销 rdy 会丢数据（包级流控，需下游保证整包接收） |
| IDLE 分支未清零 `dout_eop/mty/sop` | 仅 `dout_vld <= 0`；下游以 vld 门控时无影响，但不够严谨 |
| 数据 FIFO 深度 65536 | 远超单包最大长度，正常使用无溢出风险 |
| 校验和组合逻辑路径 | 10 个 16 位字加法树在 100 MHz 下无时序压力；若需更高频率可打拍寄存 |

---

## 四、校验和实现参考

### 4.1 算法原理（文档第 3、4 页）

1. 每 16 位为一组求和；
2. 结果超过 16 位时，**最高位（进位）回卷加到低 16 位**；
3. 全部字段相加完毕后**取反**，即为校验和。

**IP 与 UDP 的区别**（文档"问题解答 a"）：

- **IP**：只覆盖 IP 首部 20 字节（10 个字），校验和字段自身置 0 参与计算；
- **UDP**：覆盖 **伪首部(12 字节) + UDP 首部(8 字节) + 数据部分**，校验和字段置 0。

伪首部 12 字节 = 源 IP(4) + 目的 IP(4) + 0x00(1) + 协议 17(1) + UDP 长度(2)，**仅用于计算，不随包发送**。

### 4.2 数据部分校验和（接收时逐拍累加）

```verilog
reg  [15:0] r_check_res, r_check_res_tmp;
wire [15:0] w_check_word;

// mty=1 时最后一拍只有高字节有效，低字节补 0（需与上游约定）
assign w_check_word = (tx_eop && tx_mty) ? {tx_data[15:8], 8'h00} : tx_data;

wire [16:0] w_chk_sum   = {1'b0, r_check_res} + {1'b0, w_check_word};
wire [16:0] w_chk_fold1 = w_chk_sum[15:0]   + w_chk_sum[16];      // 进位回卷
wire [15:0] w_chk_fold2 = w_chk_fold1[15:0] + w_chk_fold1[16];    // 二次回卷

always @(posedge clk or negedge rst_n) begin
    if(rst_n==0)      r_check_res <= 0;
    else if(tx_vld)   r_check_res <= r_check_res_tmp;
end

always @(*) begin
    if(tx_vld && tx_sop)  r_check_res_tmp = w_check_word;   // 首拍重置累加器
    else if(tx_vld)       r_check_res_tmp = w_chk_fold2;
    else                  r_check_res_tmp = r_check_res;
end
```

**要点**：累加结果随 `{w_data_bytes, r_check_res_tmp}` 在 EOP 时写入 message FIFO，发送时从 `w_message_dout[15:0]` 取用。

> 这样设计是合理的：一补码和满足结合律，先逐拍累加、后与头部一起求和，与整体求和等价；**无需重读数据 FIFO**（数据此时还存放在 data FIFO 中）。

### 4.3 IP 首部校验和（10 字 → 折叠 → 取反）

```verilog
wire [19:0] w_ip_sum;
wire [16:0] w_ip_sum_f1;
wire [15:0] w_ip_sum_f2, w_ip_check;

assign w_ip_sum = {4'd0, 16'h4500}                  // 版本4+首部长度5+区分服务0
                + {4'd0, w_ip_total_len}            // 总长度
                + {4'd0, r_cnt_id}                  // 标识
                + {4'd0, 16'h0000}                  // 标志+片偏移(文档示例为4000)
                + {4'd0, 16'hff11}                  // TTL=255 + 协议=17
                + {4'd0, 16'h0000}                  // 校验和字段占位
                + {4'd0, cfg_sip[31:16]} + {4'd0, cfg_sip[15:0]}
                + {4'd0, cfg_dip[31:16]} + {4'd0, cfg_dip[15:0]};

assign w_ip_sum_f1 = w_ip_sum[15:0] + w_ip_sum[19:16];   // 10字和≤0x9FFF6，20位足够
assign w_ip_sum_f2 = w_ip_sum_f1[15:0] + w_ip_sum_f1[16];
assign w_ip_check  = ~w_ip_sum_f2;                       // 取反

assign w_ip_head = {4'd4, 4'd5, 8'd0, w_ip_total_len, r_cnt_id, 3'd0, 13'd0,
                    8'd255, 8'd17, w_ip_check, cfg_sip, cfg_dip};   // 160位
```

### 4.4 UDP 校验和（伪首部6字 + 首部3字 + 数据1字）

```verilog
wire [19:0] w_udp_sum;
wire [16:0] w_udp_sum_f1;
wire [15:0] w_udp_sum_f2, w_udp_check_r, w_udp_check;

assign w_udp_sum = {4'd0, cfg_sip[31:16]} + {4'd0, cfg_sip[15:0]}   // 伪首部:源IP
                 + {4'd0, cfg_dip[31:16]} + {4'd0, cfg_dip[15:0]}   // 伪首部:目的IP
                 + {4'd0, 16'h0011}         // 伪首部:{8'h0, 8'd17}
                 + {4'd0, w_udp_len}        // 伪首部:UDP长度
                 + {4'd0, cfg_sport}        // UDP首部:源端口
                 + {4'd0, cfg_dport}        // UDP首部:目的端口
                 + {4'd0, w_udp_len}        // UDP首部:长度
                 + {4'd0, w_message_dout[15:0]};   // 数据校验和(来自message FIFO)

assign w_udp_sum_f1  = w_udp_sum[15:0] + w_udp_sum[19:16];
assign w_udp_sum_f2  = w_udp_sum_f1[15:0] + w_udp_sum_f1[16];
assign w_udp_check_r = ~w_udp_sum_f2;
// RFC768：校验和计算结果为 0 时发送全 1（0 表示"无校验和"）
assign w_udp_check   = (w_udp_check_r==16'h0000) ? 16'hffff : w_udp_check_r;

assign w_udp_head = {cfg_sport, cfg_dport, w_udp_len, w_udp_check};   // 64位
```

### 4.5 长度计算与发送时机陷阱

长度**必须使用接收阶段锁存进 message FIFO 的值**：

```verilog
// 接收阶段：字节数统计（组合值，仅在该包接收期间有效）
wire [15:0] w_data_bytes = (r_cnt1 + 16'd1) * 16'd2 - {15'd0, tx_mty};
assign w_message_din = {w_data_bytes, r_check_res_tmp};      // 16+16 = 32位

// 发送阶段：长度取自 FIFO 锁存值
wire [15:0] w_udp_len      = 16'd8  + w_message_dout[31:16];  // UDP = 首部8 + 数据
wire [15:0] w_ip_total_len = 16'd20 + w_udp_len;              // IP  = 首部20 + UDP
```

> ⚠️ **常见错误**：在发送阶段直接使用 `w_data_bytes`。此时 `r_cnt1` 已被清零、`tx_mty` 复位，会算出错误长度（实测会得到 2 字节，UDP 长度字段变成 `0x000a` 而非 `0x000e`）。

### 4.6 校验和实现检查清单

- [ ] 拼接中所有算术项使用**显式位宽**（`16'd8` 而非 `8`）
- [ ] 进位回卷要做**两次**（防止二次进位）
- [ ] IP 校验和字段在计算时置 0；UDP 校验和字段同样置 0
- [ ] IP/UDP 的取反约定**统一**（推荐都定义为已取反的最终值）
- [ ] UDP 校验和结果为 0 时填 `0xFFFF`（RFC768）
- [ ] `mty=1` 时无效字节补 0（并与上游确认高/低字节约定）
- [ ] 长度值取自 message FIFO，不在发送阶段重算

---

## 五、修正版验证结果

修正版实现：`sim_verify/ethernet_tx_pack_ref.v`（模块名 `ethernet_tx_pack_ref`，与原文件并存，不覆盖）。

### 5.1 用例通过情况

| 包序号 | 来源用例 | 内容 | 修正版 | 原版 |
|---|---|---|---|---|
| P0 | CASE1 | 文档举例（3 拍数据） | **PASS**（24/24 字） | FAIL（输出 288 拍后卡死） |
| P1 | CASE2 | 奇数长度 mty=1（3 字节） | **PASS**（23/23 字） | 未输出 |
| P2 | CASE3 | 背靠背包 #1 | **PASS**（22/22 字） | 未输出 |
| P3 | CASE3 | 背靠背包 #2 | **PASS**（22/22 字） | 未输出 |
| P4 | CASE4 | 长包 64 拍（128 字节） | **PASS**（85/85 字） | 未输出 |

比对内容：每一拍数据、长度字段、ID、**IP/UDP 校验和**、sop/eop/mty 标志，全部与 Python 独立计算的期望值一致。

### 5.2 与文档示例逐字核对（CASE1）

输入数据 `0x000a, 0x0001, 0x0014`，修正版实测输出：

```
MAC  0102 0304 0506 2c02 0304 0507 0800              ✓ 与文档一致
IP   4500 0022 0000 0000 ff11 3867 c0a8 010a c0a8 0109
UDP  1388 0bb8 000e 5d0f                              ✓ 校验和 5d0f 与文档一致
DAT  000a 0001 0014                                   ✓
```

其中：

- UDP 校验和 `0x5d0f` **与文档示例完全一致**；
- IP 校验和 `0x3867` 是因为标志位取 `0x0000`；**将标志改为 `0x4000` 后计算结果为 `0xf866`，与文档示例完全一致**（见问题⑨）；
- 首包 IP 标识为 `0x0000` ✓（修正了递增时机问题）。

### 5.3 关键中间结果

| 检查项 | 数值 | 说明 |
|---|---|---|
| 数据字节数 | `(3拍×2) - 0 = 6` | `(r_cnt1+1)*2 - mty` |
| UDP 长度 | `8+6 = 14 = 0x000e` | ✓ |
| IP 总长度 | `20+14 = 34 = 0x0022` | ✓ |
| 数据校验和（未取反） | `0x000a+0x0001+0x0014 = 0x001f` | 一补码和 |
| IP 头 10 字和 | `0xC798` → 取反 `0x3867` | |
| UDP 伪首部+头+数据 10 字和 | `0xA2F0` → 取反 `0x5D0F` | ✓ 与文档示例一致 |

---

## 六、修改后代码复核（第二轮验证，2026-10-07）

### 6.1 复核结果总览

| 编号 | 第一轮问题 | 状态 | 说明 |
|---|---|---|---|
| ① | `w_udp2data_start` 未赋值 | ✅ 已修复 | 第 261 行补上赋值 |
| ② | UDP 状态拍数 `8-1` | ✅ 已修复 | 改为 `4-1`（第 235 行） |
| ③ | 拼接位宽（unsized 常量） | ⚠️ 部分修复 | 主要表达式已改；**第 227 行仍残留一处 `8+...`** |
| ④ | `w_message_din` 33→32 位截断 | ✅ 已修复 | 改为取 `r_check_res_tmp[15:0]` |
| ⑤ | IP 标识递增时机 | ✅ 已修复 | 改到 `w_message_rd_en`（整包发送完毕） |
| ⑥ | 校验和未实现 | ❌ 未完成 | 两个 check 信号仍悬空（实现方案见第七节） |
| ⑦ | 数据校验和二次进位 | ✅ 已修复 | `tmp = tmp + tmp[16]` 写法数学上正确 |
| ⑧ | `mty=1` 未补零 | ✅ 已修复 | 取 `{tx_data[15:8], 8'd0}` |
| ⑨ | 文档与代码差异 | — | 见 6.2 (3)，IP 标志位待确认 |
| ⑩ | IDLE 分支未清零输出 | ✅ 已修复 | 5 个输出全部补齐清零 |

另新增合理改动：`dout_rdy` 加入 MAC/IP/UDP 计数器使能（175/205/234 行），
使流控粒度从"包级"细化到"拍级"，建议保留。

### 6.2 本轮新发现的问题

#### (1) IP 总长度少算 8 字节【第一轮报告遗漏项，此处补充】

```verilog
198 行:  16'd20+w_message_dout[31:16]     // = 20 + 数据字节数  ✗
```

IP 总长应为 `IP首部(20) + UDP长度`，而 **UDP 长度 = UDP首部(8) + 数据字节数**。
实测：文档示例应为 `0x0022`(34)，当前表达式输出 `0x001a`(26)，相差正好 8 字节。

修正写法：

```verilog
wire [15:0] w_udp_len      = 16'd8  + w_message_dout[31:16];   // UDP长度
wire [15:0] w_ip_total_len = 16'd20 + w_udp_len;               // IP总长
// w_ip_head_tmp / w_ip_head 中改用 w_ip_total_len
```

#### (2) 第 227 行残留 unsized 常量

```verilog
assign w_udp_head_tmp = {..., 16'd8+w_message_dout[31:16], cfg_sport, cfg_dport,
                             8+w_message_dout[31:16], ...};
//                           ^^ 应为 16'd8+
```

该信号目前未被使用（死代码），但若按第七节方案用它做校验和求和，这处会直接算错。

#### (3) 待确认项

IP 标志位仍为 `0x0000`（按文档文字"固定为0"），而文档第 4 页示例为 `0x4000`；
只有取 `0x4000` 才能复现示例校验和 `f866`。请按实际需求确认。

### 6.3 复核验证方法与结果

把修改后的代码补齐校验和、并修正上述 (1) 后做成 `sim_verify/ethernet_tx_pack_v2.v`，
与第一轮已验证的参考实现（`ethernet_tx_pack_ref.v`）**同激励并行仿真、逐字对比**：

| 包 | 内容 | 结果 |
|---|---|---|
| P0 | 文档举例（24 字） | 完全一致 |
| P1 | 奇数长度 mty=1（23 字） | 完全一致 |
| P2/P3 | 背靠背两包（各 22 字） | 完全一致 |
| P4 | 长包 128 字节（85 字） | 完全一致 |

未驱动信号扫描：仅 `w_ip_head_check`、`w_udp_head_check` 悬空（即问题⑥）。

> 校验和实现的时序实测与优化方案见第七节。

---

## 七、校验和时序分析与优化（实测）

> 本节回答"校验和一次性大量加法是否会来不及算完"的问题，结论基于 Vivado 2020.2
> 实际综合（xc7k70tfbg676-2，100 MHz，含真实加法树）。

### 7.1 功能层面：不会算错

组合逻辑并非"每个时钟周期重新计算"，而是**输入变化后经过延迟 D 稳定，再被时钟沿采样**。
校验和的三个输入在包开始发送前就已稳定、且整个包头输出期间不变：

| 输入 | 稳定时机 |
|---|---|
| `w_message_dout`（长度+数据校验和） | FWFT FIFO 非空时即有效，发送期间不被读 |
| `cfg_sip/dip/sport/dport` | 配置寄存器，运行期不变 |
| `r_cnt_id` | 仅在该包发送完毕时 +1 |

IP 校验和字段在进入 MAC 后第 12 拍才输出，**距输入稳定 ≥ 120 ns**，
而加法树延迟仅数 ns——采样时刻的值一定已经算完。

### 7.2 时序层面：确实是关键路径，建议优化

静态时序分析（STA）按最坏路径分析"FIFO 读指针 → 组合逻辑 → 输出寄存器"，
实测综合结果：

| 指标 | 组合加法树实现 | 逐拍累加实现 |
|---|---|---|
| **WNS（最差裕量）** | **+1.642 ns** | **+5.574 ns** |
| 关键路径延迟 | 7.832 ns | 3.900 ns |
| 逻辑级数 | 20 级（CARRY4×12） | 9 级（CARRY4×5） |
| 布线占比 | 4.920 ns（63%） | 2.389 ns（61%） |
| 关键路径 | rd_ptr → 10字加法 → dout_data | rd_ptr → 位选+1次加法 → 累加器 |

组合实现虽在综合阶段勉强满足（+1.6 ns），但**布线占 63%、余量小，布局布线后
很可能违规**。原因：插入末端寄存器无法缩短"FIFO 读 + 加法树"这条组合链，
必须把加法拆分。

### 7.3 优化方案：逐拍累加（实测功能一致）

利用 MAC(7拍) + IP(前3拍) 的空档，每拍只加一个字，10 个字 10 拍加完：

```verilog
    reg  [19:0] r_ip_sum, r_udp_sum;
    reg  [4:0]  r_sum_idx;
    wire [15:0] w_ip_word  = w_ip_head_tmp [159 - r_sum_idx*16 -: 16];
    wire [15:0] w_udp_word = w_udp_head_tmp[159 - r_sum_idx*16 -: 16];

    // MAC 状态对应第 0~6 字，IP 状态前 3 拍对应第 7~9 字
    always @(*) begin
        if(r_state_c==MAC) r_sum_idx = {3'd0, r_cnt_mac};
        else               r_sum_idx = 5'd7 + r_cnt_ip[3:0];
    end

    always @(posedge clk or negedge rst_n) begin
        if(rst_n==0) begin
            r_ip_sum <= 0; r_udp_sum <= 0;
        end
        else if(r_state_c==IDLE) begin                 // 包开始前清零
            r_ip_sum <= 0; r_udp_sum <= 0;
        end
        else if(r_state_c==MAC || (r_state_c==IP && r_cnt_ip<3)) begin
            r_ip_sum  <= r_ip_sum  + {4'd0, w_ip_word };
            r_udp_sum <= r_udp_sum + {4'd0, w_udp_word};
        end
    end

    // 折叠再取反（累加完成后只有 2 次 16 位加法的短路径）
    wire [16:0] w_ip_sum_f1  = r_ip_sum[15:0]  + r_ip_sum[19:16];
    wire [15:0] w_ip_sum_f2  = w_ip_sum_f1[15:0]  + w_ip_sum_f1[16];
    assign w_ip_head_check   = w_ip_sum_f2;

    wire [16:0] w_udp_sum_f1 = r_udp_sum[15:0] + r_udp_sum[19:16];
    wire [15:0] w_udp_sum_f2 = w_udp_sum_f1[15:0] + w_udp_sum_f1[16];
    assign w_udp_head_check  = (w_udp_sum_f2 == 16'hffff) ? 16'h0000 : w_udp_sum_f2;
```

原理：1 的补码和满足结合律，先累加后折叠与逐拍折叠等价（累加器 20 位足够容纳
10 个字的最大和 0x9FFF6）。实测 5 个测试包输出与参考实现**完全一致**。

实现文件：`sim_verify/ethernet_tx_pack_v3.v`（逐拍累加）、`sim_verify/ethernet_tx_pack_v2.v`（组合版对照）。

### 7.4 结论

- 功能上不会"来不及算完"，但**组合实现会成为时序关键路径**（余量仅 1.6 ns）；
- 推荐采用**逐拍累加**：余量提升至 5.6 ns，关键路径缩短 50%，功能实测一致；
- 若坚持组合实现，请在实现（place & route）后检查 WNS，必要时再流水化。

---

## 八、第三轮验证（2026-10-07）：校验和实现复核

### 8.1 本轮修改概述

用户对本模块做了较大重构，主要变化：

1. **校验和改为"逐拍累加"实现**（IP 与 UDP 各一套）：
   用 `r_flag_cnt_ip_chk` / `r_flag_cnt_udp_chk` 在 `w_idle2mac_start`（包开始发送）时启动，
   在 MAC(7拍) + IP(前3拍) 的空档逐拍累加，10 个字加满后自动停止；
   累加器 `r_ip_head_sum`/`r_udp_head_sum` 为 20 位，折叠逻辑独立为 `_f0`/`_f1` 两级；
2. 计数器 `r_cnt_ip`、`r_cnt_udp` 位宽调整为 4 位（10 拍/4 拍需求）；
3. 信号声明集中到模块头部（编码风格调整）。

> 该思路与第七节建议的"逐拍累加/时序优化"完全一致，实现方式（flag + 独立计数器）略有不同但等效。

### 8.2 静态检查结果

| 检查项 | 结果 |
|---|---|
| 未驱动信号 | **无** ✓（校验和已实现） |
| 拼接中的 unsized 常量 | **无** ✓（上一轮 227 行的问题已修复） |
| 位选索引范围 | 正常 ✓（4 位计数器覆盖 0~9） |
| **IP 总长度表达式** | ❌ **仍为 `16'd20+w_message_dout[31:16]`（第 235/236 行）** |

### 8.3 仿真验证结果（对照已验证的参考实现，逐字比对）

| 包 | 内容 | 结果 |
|---|---|---|
| P0 | 文档举例（24 字） | 差异 2 处：IP 总长、IP 校验和 |
| P1 | 奇数长度 mty=1（23 字） | 差异 2 处：同上 |
| P2/P3 | 背靠背两包（各 22 字） | 差异 2 处：同上 |
| P4 | 长包 128 字节（85 字） | 差异 2 处：同上 |

**唯一差异 = IP 总长及其连带的 IP 校验和**，其余字段（MAC 头、IP 头其余字段、
UDP 长度、**UDP 校验和、数据**）全部正确：

```
当前版: 4500 001a 0000 0000 ff11 386f c0a8 010a c0a8 0109 1388 0bb8 000e 5d0f ...
参考版: 4500 0022 0000 0000 ff11 3867 c0a8 010a c0a8 0109 1388 0bb8 000e 5d0f ...
        ^^^^^^^^^^ IP总长差 8                    UDP 校验和 5d0f 与文档示例一致 ✓
```

差异原因：`20 + 数据字节数(6) = 26`，正确应为 `20 + UDP长度(14) = 34`（少 UDP 首部 8 字节），
IP 校验和因总长字段错误而连带不同。

### 8.4 修正验证：仅改 IP 总长即 100% 一致

把 `16'd20+...` 改为 `16'd28+...`（等价于 20+8+数据字节数）后重新仿真：

| 包 | 结果 |
|---|---|
| 文档举例 / 奇数长度 / 背靠背×2 / 长包 | **全部完全一致** ✓ |
| **rdy 暂停恢复**（新增边界用例） | **完全一致** ✓ |

说明：逐拍累加实现、`dout_rdy` 拍级流控增强**均正确**，IP 总长是唯一遗留问题。

### 8.5 时序实测（Vivado 2020.2，xc7k70t，100 MHz）

| 实现方式 | WNS | 关键路径延迟 | 逻辑级数 |
|---|---|---|---|
| 组合加法树（第一版） | +1.642 ns | 7.832 ns | 20 |
| 参考优化版 v3 | +5.574 ns | 3.900 ns | 9 |
| **本轮用户实现** | **+5.681 ns** | **3.806 ns** | **8** |

关键路径：`u_tx_message_fifo/rd_ptr` → `r_udp_head_sum[17]`（每拍一次 20 位加法），
时序余量从 1.6 ns 提升到 5.7 ns，**校验和路径不再是瓶颈** ✓

### 8.6 本轮遗留项

1. **IP 总长度少 8 字节**（第 235/236 行）——唯一功能性遗留，必须修；
2. `r_flag_cnt_udp_chk <= r_flag_cnt_udp_chk+1`（第 314 行）：该信号为 1 位，
   正常时序下等价于置 1，但建议与 IP 侧统一写成 `<= 1'b1` 更清晰、避免误解；
3. UDP 校验和为 0 时应发送全 1（RFC768）——当前未做该特例映射（触发概率极低，可选）；
4. IP 标志位 `0x0000` vs 文档示例 `0x4000`——待确认。

---

## 九、建议修改顺序（第三轮更新）

### 9.1 已完成项

**第一轮 10 项问题**：9 项已修复（①~⑤、⑦⑧⑩），第 ⑥ 项（校验和）在第三轮完成实现。

**第二轮遗留 3 项**：

| 项 | 状态 |
|---|---|
| 实现校验和 | ✅ 第三轮完成（逐拍累加，时序 WNS +5.681ns） |
| 第 227 行残留位宽 | ✅ 已修复 |
| 修正 IP 总长度 | ❌ **仍未修复**（唯一功能性遗留） |

### 9.2 当前遗留项（按优先级）

1. **【必须】修正 IP 总长度**——第 235/236 行两处：

   ```verilog
   16'd20+w_message_dout[31:16]   →   16'd28+w_message_dout[31:16]
   ```
   （28 = IP首部 20 + UDP首部 8。实测修正后 6 个测试用例与参考实现 100% 一致）

2. **【建议】第 314 行写法统一**：`r_flag_cnt_udp_chk <= r_flag_cnt_udp_chk+1`
   → `<= 1'b1`（该信号仅 1 位，正常时序下两者等价，但前者语义易引起误解）

3. **【可选】UDP 校验和为 0 时发送全 1**（RFC768，触发概率极低）

4. **【待确认】** IP 标志位取 `0x0000` 还是 `0x4000`（文档示例为 `0x4000`）；
   `mty=1` 时有效字节是高 8 位还是低 8 位

5. **【回归】** 修改后用 `sim_verify/` 平台重新仿真，与文档第 4 页示例逐字核对
   （期望：IP 校验和 `f866`（标志取 `0x4000` 时）、UDP 校验和 `5d0f`）

---

## 附录

### 附录 A：相关文件

```
project_ethernet/
├── project_ethernet.srcs/sources_1/new/ethernet_tx_pack.v   ← 原模块（本报告验证对象）
├── tx_pack功能文档.pdf                                        ← 设计依据
├── tx_pack验证报告.md                                         ← 本报告
└── sim_verify/                                                ← 仿真工程
    ├── ethernet_tx_pack_ref.v     修正版参考实现（含 [FIX-n] 标注）
    ├── tb_compare.v               双 DUT 对比测试平台
    ├── tb_ethernet_tx_pack.v      单模块测试平台（初版）
    ├── run_sim.bat / elab_run.bat 编译脚本
    └── compare_full.log           仿真输出日志
```

### 附录 B：修正版标注索引（ethernet_tx_pack_ref.v）

| 标注 | 对应问题 | 内容 |
|---|---|---|
| `[FIX-1]` | ③ | 拼接表达式显式位宽 |
| `[FIX-2]` | ④ | `w_message_din` 修正为 32 位 |
| `[FIX-3]` | ⑥ | IP 首部校验和实现 |
| `[FIX-4]` | ⑥ | UDP 校验和实现（含伪首部） |
| `[FIX-5]` | ⑦⑧ | 数据校验和折叠修正 + mty 补零 |
| `[FIX-6]` | ⑤ | IP 标识递增时机 |
| `[FIX-7]` | ① | 补 `w_udp2data_start` 赋值 |
| `[FIX-8]` | ② | UDP 状态拍数 `4-1` |
| `[FIX-9]` | §4.5 | 发送阶段长度取自 message FIFO |

### 附录 C：复现仿真的命令

WSL 环境下（Linux 版 Vivado 脚本不可用，须经 `cmd.exe` 调用 Windows 版）：

```bat
:: 在 sim_verify 目录下执行
set RDI_DATADIR=D:\software\vivado\Vivado\2020.2\data
copy /y %RDI_DATADIR%\xsim\xsim.ini .

xvlog -L unisims_ver glbl.v tb_compare.v ^
      ..\project_ethernet.srcs\sources_1\new\ethernet_tx_pack.v ^
      ethernet_tx_pack_ref.v ^
      ..\project_ethernet.gen\sources_1\ip\fifo_19x65536_fwft_sync\fifo_19x65536_fwft_sync_sim_netlist.v ^
      ..\project_ethernet.gen\sources_1\ip\fifo_32x128_fwft_sync\fifo_32x128_fwft_sync_sim_netlist.v

xelab -L unisims_ver work.tb_compare work.glbl -s tb_cmp
xsim tb_cmp -R
```

> 要点：必须把 `xsim.ini` 复制到工作目录并设置 `RDI_DATADIR`（否则找不到 `LUT6`/`RAMB36E1` 等 unisim 原语）；必须编译 `glbl.v` 并作为顶层参与 xelab。

---

*本报告由仿真实测 + 逐字比对生成，所有结论均可在 `sim_verify/compare_full.log` 中复现。*

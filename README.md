# 吉羊货栈 · 兑礼台

元旦「吉羊市集 · 国风银票游园会」出口兑礼用的单页 Web App。工作人员输入来宾的部门+姓名查重登记，多台兑礼台实时共用一份后台，数据库唯一约束保证同一人并发也只能兑一次。

## 已部署（可直接用）

- **兑礼台页面**：https://676661713.github.io/jiyang-duilitai/ （GitHub Pages，main 分支根目录）
- **后台**：Supabase 项目 `jiyang-duilitai`（Postgres 17，首尔区），管理台 https://supabase.com/dashboard/project/bwjxxhpfvsokczrkdhcs ，用 GitHub 账号 676661713 登录
- **页面源码**：https://github.com/676661713/jiyang-duilitai

## 现场怎么用

1. 每台兑礼台手机/电脑浏览器打开上面的网址。
2. 填「经手人」（右上角小框，如「1号台」，每台记一次即可）。
3. 第一次点「确认兑换并回收银票」时输入**工作人员口令**（当前口令见内部交付件 `DEPLOYED_URL.txt`，不公开）。口令只记在本机浏览器里，登记时服务端校验。
4. 来宾报部门+姓名 → 查询兑换资格 → 绿色「未兑换过」→ 填银票两数（实时显示档位）→ 确认 → 「登记成功，请发放：××礼」。
5. 管理员点右上「管理」输**管理口令**（同上，见 `DEPLOYED_URL.txt`）后可：作废记录（列表里点「作废」，页内二次确认，作废后此人可再兑换）、改大礼份数、改两个口令。

## 档位规则

| 银票 | 档位 |
|---|---|
| 10 两及以上 | 大礼（限量，默认 50 份，先到先得） |
| 6–9 两 | 中礼 |
| 3–5 两 | 小礼 |
| 0–2 两 | 福羊纪念保底礼 |

大礼兑完后 10 两及以上自动按中礼发，记录标注「大礼已兑完，按中礼兑换」，数量只算进中礼。

## 查重口径

key = `规范化(部门)+"|"+规范化(姓名)`，规范化 = 去掉所有空格（含全角空格）+ 英文不区分大小写 + NFKC（全角字母数字按半角算）。同部门同名的两个人会被当成同一人——**已知限制**，正式版建议加第三字段（工号或手机号后四位）。

## 架构与并发安全

- 页面是零依赖单文件 `index.html`，纯 fetch，每 2.5 秒轮询后台刷新统计和记录；断连约 10 秒顶部出红色横幅「暂时连不上兑换后台」。
- 写操作全部走 Postgres `security definer` RPC（`redeem`/`admin_void`/`admin_set_stock`/`admin_set_codes`），anon key 只有读权限，口令在服务端校验、不落前端。
- 并发：`redemptions.key` 主键唯一约束 + RPC 内 `config/main` 行锁（`FOR UPDATE`）串行化大礼份数扣减，两台同时登记同一人只有一台成功，另一台收到「已兑换过」。
- 作废不真删：先进 `redemptions_void` 留档再删，管理员可用 SQL 查回。
- 页面访问口令 = `secrets` 表两行：staff_code（工作人员口令）、admin_pass（管理口令）。页面源码里的 `sb_publishable_` key 本来就是给前端用的公开 key，不是秘密。

## 口令怎么改

推荐直接在页面里改：右上「管理」→ 输管理口令 → 填「新工作人员口令 / 新管理口令」→ 保存。改完各兑礼台下次登记时用新口令（旧口令报错后重新输入即可）。

也可直接改库（Supabase 管理台 SQL Editor）：

```sql
update public.secrets set staff_code='新工作口令', admin_pass='新管理口令' where id='main';
update public.config set big_stock=50 where id='main';   -- 改大礼份数
```

## 重新部署 / 迁移

本项目=前端静态页 + Supabase 库两部分，互不绑定：

- **页面换托管**：`index.html` 是单文件，丢到任何静态托管都行（Pages/Netlify/公司服务器）。页面里的 `SB_URL`、`SB_KEY` 两个常量改不改取决于后台换不换。
- **从零建后台**：`schema.sql` 幂等，新 Supabase 项目 SQL Editor 里整段跑一次即可（含表、RPC、RLS、realtime publication、storage 桶、默认口令）。
- **改页面**：改 `index.html` → 推到 `676661713/jiyang-duilitai` main 分支（GitHub 网页上传也行）→ Pages 约 1 分钟生效。
- 备用托管入口：项目里还留了一个 Supabase Edge Function `app`（单文件托管版）和一个 `web` 公共桶；注意 Supabase 网关强制 `text/plain + nosniff`，**不能直接用来当网页**，仅作源码备份。

## 现场注意

- 兑礼设备必须联网；免费 Supabase 项目闲置约 7 天会休眠，**活动当天早上先开一次页面唤醒**（或提前在管理台禁用休眠）。
- 页面公开可访问：任何拿到网址的人都能看到兑换记录（匿名只读），登记要工作人员口令；活动结束想关站：删 GitHub 仓库或把仓库转 private（Pages 即失效），或在 Supabase 删掉 anon 读策略。
- 大礼份数按真实预算在管理页改，别用默认 50 当正式数。
- 断网/写失败时页面会提示重试，不会丢已确认的记录。

## 文件

| 文件 | 说明 |
|---|---|
| `index.html` | 全部前端（页面+逻辑+样式），零依赖单文件 |
| `schema.sql` | 建库脚本：表/函数/RLS/实时/默认口令，幂等 |
| `edge-fn-app.ts` | 备用：Supabase Edge Function 版托管源码（当前域名被强制 nosniff 不能用，仅存档） |
| `DEPLOYED_URL.txt` | 已部署地址与默认口令速查 |

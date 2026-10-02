# 把 agents 用量控件加到状态栏右侧，且**只在尚未存在时**添加。
#
# 为什么不放进 desktop-settings.json：那份文件走的是 `jq '.[0] * .[1]'` 浅合并，
# 数组会被整体替换——barConfigs 一旦进去，每次重装都会清掉用户自己的状态栏布局。
#
# **没有现成的 barConfigs 时什么都不做。** DMS 读设置是整体赋值（`root[k] = raw`），它的默认
# 状态栏（启动器/工作区/焦点窗口、音乐/时钟/天气、系统托盘/剪贴板/CPU/内存/通知/电池/控制中心）
# 只在"键不存在"时生效。如果我们在这里凭空造一个只含本控件的栏，全新机器上用户会得到一个
# 几乎是空的顶栏——这比"控件没显示"严重得多。宁可少显示一个控件。
#
# 幂等：重复执行不会出现第二个同名控件。
def widget_id: if type == "object" then .id else . end;

def widget_present:
    [.barConfigs[]?
     | (.leftWidgets? // [])[], (.centerWidgets? // [])[], (.rightWidgets? // [])[]
     | widget_id] | index("cachyosAgents") != null;

if widget_present then
    .
elif ((.barConfigs // []) | length) == 0 then
    # 不动：交给 DMS 用它自己的默认栏。用户可在 设置 → 状态栏 里手动添加本控件。
    .
else
    .barConfigs[0].rightWidgets =
        ((.barConfigs[0].rightWidgets // []) + [{"id": "cachyosAgents", "enabled": true}])
end
